-- Copyright (c) 2019 The DAML Authors. All rights reserved.
-- SPDX-License-Identifier: Apache-2.0

{-# LANGUAGE CPP                   #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE DuplicateRecordFields #-}
#include "ghc-api-version.h"

-- | A Shake implementation of the compiler service, built
--   using the "Shaker" abstraction layer for in-memory use.
--
module Development.IDE.Core.Rules(
    IdeState, GetDependencies(..), GetParsedModule(..), TransitiveDependencies(..),
    Priority(..), GhcSessionIO(..), GetClientSettings(..),
    priorityTypeCheck,
    priorityGenerateCore,
    priorityFilesOfInterest,
    runAction, useE, useNoFileE, usesE,
    toIdeResult,
    defineNoFile,
    defineEarlyCutOffNoFile,
    mainRule,
    getAtPoint,
    getDefinition,
    getTypeDefinition,
    highlightAtPoint,
    getDependencies,
    getParsedModule,
    ) where

import Fingerprint

import Data.Binary hiding (get, put)
import Data.Tuple.Extra
import Control.Monad.Extra
import Control.Monad.Trans.Class
import Control.Monad.Trans.Maybe
import Development.IDE.Core.Compile
import Development.IDE.Core.OfInterest
import Development.IDE.Types.Options
import Development.IDE.Spans.Documentation
import Development.IDE.Spans.LocalBindings
import Development.IDE.Import.DependencyInformation
import Development.IDE.Import.FindImports
import           Development.IDE.Core.FileExists
import           Development.IDE.Core.FileStore        (modificationTime, getFileContents)
import           Development.IDE.Types.Diagnostics as Diag
import Development.IDE.Types.Location
import Development.IDE.GHC.Compat hiding (parseModule, typecheckModule, writeHieFile, TargetModule, TargetFile)
import Development.IDE.GHC.Util
import Development.IDE.GHC.WithDynFlags
import Data.Either.Extra
import qualified Development.IDE.Types.Logger as L
import Data.Maybe
import           Data.Foldable
import qualified Data.IntMap.Strict as IntMap
import Data.IntMap.Strict (IntMap)
import Data.List
import qualified Data.Set                                 as Set
import qualified Data.Map as M
import qualified Data.Text                                as T
import qualified Data.Text.Encoding                       as T
import           Development.IDE.GHC.Error
import           Development.Shake                        hiding (Diagnostic)
import Development.IDE.Core.RuleTypes
import qualified Data.ByteString.Char8 as BS
import Development.IDE.Core.PositionMapping
import           Language.Haskell.LSP.Types (DocumentHighlight (..))

import qualified GHC.LanguageExtensions as LangExt
import HscTypes hiding (TargetModule, TargetFile)
import PackageConfig
import DynFlags (gopt_set, xopt)
import GHC.Generics(Generic)

import qualified Development.IDE.Spans.AtPoint as AtPoint
import Development.IDE.Core.IdeConfiguration
import Development.IDE.Core.Service
import Development.IDE.Core.Shake
import Development.Shake.Classes hiding (get, put)
import Control.Monad.Trans.Except (runExceptT)
import Data.ByteString (ByteString)
import Control.Concurrent.Async (concurrently)
import System.Time.Extra
import Control.Monad.Reader
import System.Directory ( getModificationTime )
import Control.Exception

import Control.Monad.State
import FastString (FastString(uniq))
import qualified HeaderInfo as Hdr
import Data.Time (UTCTime(..))
import Data.Hashable
import qualified Data.HashSet as HashSet
import qualified Data.HashMap.Strict as HM
import TcRnMonad (tcg_dependent_files)
import Data.IORef

-- | This is useful for rules to convert rules that can only produce errors or
-- a result into the more general IdeResult type that supports producing
-- warnings while also producing a result.
toIdeResult :: Either [FileDiagnostic] v -> IdeResult v
toIdeResult = either (, Nothing) (([],) . Just)

-- | useE is useful to implement functions that aren’t rules but need shortcircuiting
-- e.g. getDefinition.
useE :: IdeRule k v => k -> NormalizedFilePath -> MaybeT IdeAction (v, PositionMapping)
useE k = MaybeT . useWithStaleFast k

useNoFileE :: IdeRule k v => IdeState -> k -> MaybeT IdeAction v
useNoFileE _ide k = fst <$> useE k emptyFilePath

usesE :: IdeRule k v => k -> [NormalizedFilePath] -> MaybeT IdeAction [(v,PositionMapping)]
usesE k = MaybeT . fmap sequence . mapM (useWithStaleFast k)

defineNoFile :: IdeRule k v => (k -> Action v) -> Rules ()
defineNoFile f = define $ \k file -> do
    if file == emptyFilePath then do res <- f k; return ([], Just res) else
        fail $ "Rule " ++ show k ++ " should always be called with the empty string for a file"

defineEarlyCutOffNoFile :: IdeRule k v => (k -> Action (ByteString, v)) -> Rules ()
defineEarlyCutOffNoFile f = defineEarlyCutoff $ \k file -> do
    if file == emptyFilePath then do (hash, res) <- f k; return (Just hash, ([], Just res)) else
        fail $ "Rule " ++ show k ++ " should always be called with the empty string for a file"


------------------------------------------------------------
-- Exposed API

-- | Get all transitive file dependencies of a given module.
-- Does not include the file itself.
getDependencies :: NormalizedFilePath -> Action (Maybe [NormalizedFilePath])
getDependencies file = fmap transitiveModuleDeps <$> use GetDependencies file

-- | Try to get hover text for the name under point.
getAtPoint :: NormalizedFilePath -> Position -> IdeAction (Maybe (Maybe Range, [T.Text]))
getAtPoint file pos = fmap join $ runMaybeT $ do
  ide <- ask
  opts <- liftIO $ getIdeOptionsIO ide

  (hieAst -> hf, mapping) <- useE GetHieAst file
  dkMap <- lift $ maybe (DKMap mempty mempty) fst <$> (runMaybeT $ useE GetDocMap file)

  !pos' <- MaybeT (return $ fromCurrentPosition mapping pos)
  return $ AtPoint.atPoint opts hf dkMap pos'

-- | Goto Definition.
getDefinition :: NormalizedFilePath -> Position -> IdeAction (Maybe Location)
getDefinition file pos = runMaybeT $ do
    ide <- ask
    opts <- liftIO $ getIdeOptionsIO ide
    (HAR _ hf _ imports, mapping) <- useE GetHieAst file
    !pos' <- MaybeT (return $ fromCurrentPosition mapping pos)
    AtPoint.gotoDefinition (getHieFile ide file) opts imports hf pos'

getTypeDefinition :: NormalizedFilePath -> Position -> IdeAction (Maybe [Location])
getTypeDefinition file pos = runMaybeT $ do
    ide <- ask
    opts <- liftIO $ getIdeOptionsIO ide
    (hieAst -> hf, mapping) <- useE GetHieAst file
    !pos' <- MaybeT (return $ fromCurrentPosition mapping pos)
    AtPoint.gotoTypeDefinition (getHieFile ide file) opts hf pos'

highlightAtPoint :: NormalizedFilePath -> Position -> IdeAction (Maybe [DocumentHighlight])
highlightAtPoint file pos = runMaybeT $ do
    (HAR _ hf rf _,mapping) <- useE GetHieAst file
    !pos' <- MaybeT (return $ fromCurrentPosition mapping pos)
    AtPoint.documentHighlight hf rf pos'

getHieFile
  :: ShakeExtras
  -> NormalizedFilePath -- ^ file we're editing
  -> Module -- ^ module dep we want info for
  -> MaybeT IdeAction (HieFile, FilePath) -- ^ hie stuff for the module
getHieFile ide file mod = do
  TransitiveDependencies {transitiveNamedModuleDeps} <- fst <$> useE GetDependencies file
  case find (\x -> nmdModuleName x == moduleName mod) transitiveNamedModuleDeps of
    Just NamedModuleDep{nmdFilePath=nfp} -> do
        let modPath = fromNormalizedFilePath nfp
        hieFile <- getHomeHieFile nfp
        return (hieFile, modPath)
    _ -> getPackageHieFile ide mod file

getHomeHieFile :: NormalizedFilePath -> MaybeT IdeAction HieFile
getHomeHieFile f = do
  ms <- fst <$> useE GetModSummaryWithoutTimestamps f
  let normal_hie_f = toNormalizedFilePath' hie_f
      hie_f = ml_hie_file $ ms_location ms

  mbHieTimestamp <- either (\(_ :: IOException) -> Nothing) Just <$> (liftIO $ try $ getModificationTime hie_f)
  srcTimestamp   <- MaybeT (either (\(_ :: IOException) -> Nothing) Just <$> (liftIO $ try $ getModificationTime $ fromNormalizedFilePath f))
  liftIO $ print (mbHieTimestamp, srcTimestamp, hie_f, normal_hie_f)
  let isUpToDate
        | Just d <- mbHieTimestamp = d > srcTimestamp
        | otherwise = False

  if isUpToDate
    then do
      ncu <- mkUpdater
      hf <- liftIO $ whenMaybe isUpToDate (loadHieFile ncu hie_f)
      MaybeT $ return hf
    else do
      wait <- lift $ delayedAction $ mkDelayedAction "OutOfDateHie" L.Info $ do
        hsc <- hscEnv <$> use_ GhcSession f
        pm <- use_ GetParsedModule f
        (_, mtm)<- typeCheckRuleDefinition hsc pm
        mapM_ (getHieAstRuleDefinition f hsc) mtm
      _ <- MaybeT $ liftIO $ timeout 1 wait
      ncu <- mkUpdater
      liftIO $ loadHieFile ncu hie_f

getSourceFileSource :: NormalizedFilePath -> Action BS.ByteString
getSourceFileSource nfp = do
    (_, msource) <- getFileContents nfp
    case msource of
        Nothing -> liftIO $ BS.readFile (fromNormalizedFilePath nfp)
        Just source -> pure $ T.encodeUtf8 source

getPackageHieFile :: ShakeExtras
                  -> Module             -- ^ Package Module to load .hie file for
                  -> NormalizedFilePath -- ^ Path of home module importing the package module
                  -> MaybeT IdeAction (HieFile, FilePath)
getPackageHieFile ide mod file = do
    pkgState  <- hscEnv . fst <$> useE GhcSession file
    IdeOptions {..} <- liftIO $ getIdeOptionsIO ide
    let unitId = moduleUnitId mod
    case lookupPackageConfig unitId pkgState of
        Just pkgConfig -> do
            -- 'optLocateHieFile' returns Nothing if the file does not exist
            hieFile <- liftIO $ optLocateHieFile optPkgLocationOpts pkgConfig mod
            path    <- liftIO $ optLocateSrcFile optPkgLocationOpts pkgConfig mod
            case (hieFile, path) of
                (Just hiePath, Just modPath) -> do
                    -- deliberately loaded outside the Shake graph
                    -- to avoid dependencies on non-workspace files
                        ncu <- mkUpdater
                        MaybeT $ liftIO $ Just . (, modPath) <$> loadHieFile ncu hiePath
                _ -> MaybeT $ return Nothing
        _ -> MaybeT $ return Nothing

-- | Parse the contents of a daml file.
getParsedModule :: NormalizedFilePath -> Action (Maybe ParsedModule)
getParsedModule file = use GetParsedModule file

------------------------------------------------------------
-- Rules
-- These typically go from key to value and are oracles.

priorityTypeCheck :: Priority
priorityTypeCheck = Priority 0

priorityGenerateCore :: Priority
priorityGenerateCore = Priority (-1)

priorityFilesOfInterest :: Priority
priorityFilesOfInterest = Priority (-2)

-- | IMPORTANT FOR HLINT INTEGRATION:
-- We currently parse the module both with and without Opt_Haddock, and
-- return the one with Haddocks if it -- succeeds. However, this may not work
-- for hlint, and we might need to save the one without haddocks too.
-- See https://github.com/digital-asset/ghcide/pull/350#discussion_r370878197
-- and https://github.com/mpickering/ghcide/pull/22#issuecomment-625070490
getParsedModuleRule :: Rules ()
getParsedModuleRule = defineEarlyCutoff $ \GetParsedModule file -> do
    _ <- use_ GetModSummaryWithoutTimestamps file -- Fail if we can't even parse the ModSummary
    sess <- use_ GhcSession file
    let hsc = hscEnv sess
        -- These packages are used when removing PackageImports from a
        -- parsed module
        comp_pkgs = mapMaybe (fmap fst . mkImportDirs (hsc_dflags hsc)) (deps sess)
    opt <- getIdeOptions
    (modTime, contents) <- getFileContents file

    let dflags    = hsc_dflags hsc
        mainParse = getParsedModuleDefinition hsc opt comp_pkgs file modTime contents

    -- Parse again (if necessary) to capture Haddock parse errors
    if gopt Opt_Haddock dflags
        then
            liftIO mainParse
        else do
            let haddockParse = getParsedModuleDefinition (withOptHaddock hsc) opt comp_pkgs file modTime contents

            -- parse twice, with and without Haddocks, concurrently
            -- we cannot ignore Haddock parse errors because files of
            -- non-interest are always parsed with Haddocks
            -- If we can parse Haddocks, might as well use them
            --
            -- HLINT INTEGRATION: might need to save the other parsed module too
            ((fp,(diags,res)),(fph,(diagsh,resh))) <- liftIO $ concurrently mainParse haddockParse

            -- Merge haddock and regular diagnostics so we can always report haddock
            -- parse errors
            let diagsM = mergeParseErrorsHaddock diags diagsh
            case resh of
              Just _
                | HaddockParse <- optHaddockParse opt
                -> pure (fph, (diagsM, resh))
              -- If we fail to parse haddocks, report the haddock diagnostics as well and
              -- return the non-haddock parse.
              -- This seems to be the correct behaviour because the Haddock flag is added
              -- by us and not the user, so our IDE shouldn't stop working because of it.
              _ -> pure (fp, (diagsM, res))


withOptHaddock :: HscEnv -> HscEnv
withOptHaddock hsc = hsc{hsc_dflags = gopt_set (hsc_dflags hsc) Opt_Haddock}


-- | Given some normal parse errors (first) and some from Haddock (second), merge them.
--   Ignore Haddock errors that are in both. Demote Haddock-only errors to warnings.
mergeParseErrorsHaddock :: [FileDiagnostic] -> [FileDiagnostic] -> [FileDiagnostic]
mergeParseErrorsHaddock normal haddock = normal ++
    [ (a,b,c{_severity = Just DsWarning, _message = fixMessage $ _message c})
    | (a,b,c) <- haddock, Diag._range c `Set.notMember` locations]
  where
    locations = Set.fromList $ map (Diag._range . thd3) normal

    fixMessage x | "parse error " `T.isPrefixOf` x = "Haddock " <> x
                 | otherwise = "Haddock: " <> x

getParsedModuleDefinition :: HscEnv -> IdeOptions -> [PackageName] -> NormalizedFilePath -> UTCTime -> Maybe T.Text -> IO (Maybe ByteString, ([FileDiagnostic], Maybe ParsedModule))
getParsedModuleDefinition packageState opt comp_pkgs file modTime contents = do
    let fp = fromNormalizedFilePath file
        buffer = textToStringBuffer <$> contents
    (diag, res) <- parseModule opt packageState comp_pkgs fp modTime buffer
    case res of
        Nothing -> pure (Nothing, (diag, Nothing))
        Just (contents, modu) -> do
            mbFingerprint <- if isNothing $ optShakeFiles opt
                then pure Nothing
                else Just . fingerprintToBS <$> fingerprintFromStringBuffer contents
            pure (mbFingerprint, (diag, Just modu))

getLocatedImportsRule :: Rules ()
getLocatedImportsRule =
    define $ \GetLocatedImports file -> do
        ms <- use_ GetModSummaryWithoutTimestamps file
        targets <- useNoFile_ GetKnownTargets
        let imports = [(False, imp) | imp <- ms_textual_imps ms] ++ [(True, imp) | imp <- ms_srcimps ms]
        env_eq <- use_ GhcSession file
        let env = hscEnvWithImportPaths env_eq
        let import_dirs = deps env_eq
        let dflags = hsc_dflags env
            isImplicitCradle = isNothing $ envImportPaths env_eq
        dflags <- return $ if isImplicitCradle
                    then addRelativeImport file (moduleName $ ms_mod ms) dflags
                    else dflags
        opt <- getIdeOptions
        let getTargetExists modName nfp
                | isImplicitCradle = getFileExists nfp
                | HM.member (TargetModule modName) targets
                || HM.member (TargetFile nfp) targets
                = getFileExists nfp
                | otherwise = return False
        (diags, imports') <- fmap unzip $ forM imports $ \(isSource, (mbPkgName, modName)) -> do
            diagOrImp <- locateModule dflags import_dirs (optExtensions opt) getTargetExists modName mbPkgName isSource
            case diagOrImp of
                Left diags -> pure (diags, Left (modName, Nothing))
                Right (FileImport path) -> pure ([], Left (modName, Just path))
                Right (PackageImport pkgId) -> liftIO $ do
                    diagsOrPkgDeps <- computePackageDeps env pkgId
                    case diagsOrPkgDeps of
                        Left diags -> pure (diags, Right Nothing)
                        Right pkgIds -> pure ([], Right $ Just $ pkgId : pkgIds)
        let (moduleImports, pkgImports) = partitionEithers imports'
        case sequence pkgImports of
            Nothing -> pure (concat diags, Nothing)
            Just pkgImports -> pure (concat diags, Just (moduleImports, Set.fromList $ concat pkgImports))

type RawDepM a = StateT (RawDependencyInformation, IntMap ArtifactsLocation) Action a

execRawDepM :: Monad m => StateT (RawDependencyInformation, IntMap a1) m a2 -> m (RawDependencyInformation, IntMap a1)
execRawDepM act =
    execStateT act
        ( RawDependencyInformation IntMap.empty emptyPathIdMap IntMap.empty
        , IntMap.empty
        )

-- | Given a target file path, construct the raw dependency results by following
-- imports recursively.
rawDependencyInformation :: [NormalizedFilePath] -> Action RawDependencyInformation
rawDependencyInformation fs = do
    (rdi, ss) <- execRawDepM (mapM_ go fs)
    let bm = IntMap.foldrWithKey (updateBootMap rdi) IntMap.empty ss
    return (rdi { rawBootMap = bm })
  where
    go :: NormalizedFilePath -- ^ Current module being processed
       -> StateT (RawDependencyInformation, IntMap ArtifactsLocation) Action FilePathId
    go f = do
      -- First check to see if we have already processed the FilePath
      -- If we have, just return its Id but don't update any of the state.
      -- Otherwise, we need to process its imports.
      checkAlreadyProcessed f $ do
          msum <- lift $ use GetModSummaryWithoutTimestamps f
          let al =  modSummaryToArtifactsLocation f msum
          -- Get a fresh FilePathId for the new file
          fId <- getFreshFid al
          -- Adding an edge to the bootmap so we can make sure to
          -- insert boot nodes before the real files.
          addBootMap al fId
          -- Try to parse the imports of the file
          importsOrErr <- lift $ use GetLocatedImports f
          case importsOrErr of
            Nothing -> do
            -- File doesn't parse so add the module as a failure into the
            -- dependency information, continue processing the other
            -- elements in the queue
              modifyRawDepInfo (insertImport fId (Left ModuleParseError))
              return fId
            Just (modImports, pkgImports) -> do
              -- Get NFPs of the imports which have corresponding files
              -- Imports either come locally from a file or from a package.
              let (no_file, with_file) = splitImports modImports
                  (mns, ls) = unzip with_file
              -- Recursively process all the imports we just learnt about
              -- and get back a list of their FilePathIds
              fids <- mapM (go . artifactFilePath) ls
              -- Associate together the ModuleName with the FilePathId
              let moduleImports' = map (,Nothing) no_file ++ zip mns (map Just fids)
              -- Insert into the map the information about this modules
              -- imports.
              modifyRawDepInfo $ insertImport fId (Right $ ModuleImports moduleImports' pkgImports)
              return fId


    checkAlreadyProcessed :: NormalizedFilePath -> RawDepM FilePathId -> RawDepM FilePathId
    checkAlreadyProcessed nfp k = do
      (rawDepInfo, _) <- get
      maybe k return (lookupPathToId (rawPathIdMap rawDepInfo) nfp)

    modifyRawDepInfo :: (RawDependencyInformation -> RawDependencyInformation) -> RawDepM ()
    modifyRawDepInfo f = modify (first f)

    addBootMap ::  ArtifactsLocation -> FilePathId -> RawDepM ()
    addBootMap al fId =
      modify (\(rd, ss) -> (rd, if isBootLocation al
                                  then IntMap.insert (getFilePathId fId) al ss
                                  else ss))

    getFreshFid :: ArtifactsLocation -> RawDepM FilePathId
    getFreshFid al = do
      (rawDepInfo, ss) <- get
      let (fId, path_map) = getPathId al (rawPathIdMap rawDepInfo)
      -- Insert the File into the bootmap if it's a boot module
      let rawDepInfo' = rawDepInfo { rawPathIdMap = path_map }
      put (rawDepInfo', ss)
      return fId

    -- Split in (package imports, local imports)
    splitImports :: [(Located ModuleName, Maybe ArtifactsLocation)]
                 -> ([Located ModuleName], [(Located ModuleName, ArtifactsLocation)])
    splitImports = foldr splitImportsLoop ([],[])

    splitImportsLoop (imp, Nothing) (ns, ls) = (imp:ns, ls)
    splitImportsLoop (imp, Just artifact) (ns, ls) = (ns, (imp,artifact) : ls)

    updateBootMap pm boot_mod_id ArtifactsLocation{..} bm =
      if not artifactIsSource
        then
          let msource_mod_id = lookupPathToId (rawPathIdMap pm) (toNormalizedFilePath' $ dropBootSuffix $ fromNormalizedFilePath artifactFilePath)
          in case msource_mod_id of
               Just source_mod_id -> insertBootId source_mod_id (FilePathId boot_mod_id) bm
               Nothing -> bm
        else bm

    dropBootSuffix :: FilePath -> FilePath
    dropBootSuffix hs_src = reverse . drop (length @[] "-boot") . reverse $ hs_src

getDependencyInformationRule :: Rules ()
getDependencyInformationRule =
    define $ \GetDependencyInformation file -> do
       rawDepInfo <- rawDependencyInformation [file]
       pure ([], Just $ processDependencyInformation rawDepInfo)

reportImportCyclesRule :: Rules ()
reportImportCyclesRule =
    define $ \ReportImportCycles file -> fmap (\errs -> if null errs then ([], Just ()) else (errs, Nothing)) $ do
        DependencyInformation{..} <- use_ GetDependencyInformation file
        let fileId = pathToId depPathIdMap file
        case IntMap.lookup (getFilePathId fileId) depErrorNodes of
            Nothing -> pure []
            Just errs -> do
                let cycles = mapMaybe (cycleErrorInFile fileId) (toList errs)
                -- Convert cycles of files into cycles of module names
                forM cycles $ \(imp, files) -> do
                    modNames <- forM files $ \fileId -> do
                        let file = idToPath depPathIdMap fileId
                        getModuleName file
                    pure $ toDiag imp $ sort modNames
    where cycleErrorInFile f (PartOfCycle imp fs)
            | f `elem` fs = Just (imp, fs)
          cycleErrorInFile _ _ = Nothing
          toDiag imp mods = (fp , ShowDiag , ) $ Diagnostic
            { _range = rng
            , _severity = Just DsError
            , _source = Just "Import cycle detection"
            , _message = "Cyclic module dependency between " <> showCycle mods
            , _code = Nothing
            , _relatedInformation = Nothing
            , _tags = Nothing
            }
            where rng = fromMaybe noRange $ srcSpanToRange (getLoc imp)
                  fp = toNormalizedFilePath' $ fromMaybe noFilePath $ srcSpanToFilename (getLoc imp)
          getModuleName file = do
           ms <- use_ GetModSummaryWithoutTimestamps file
           pure (moduleNameString . moduleName . ms_mod $ ms)
          showCycle mods  = T.intercalate ", " (map T.pack mods)

-- returns all transitive dependencies in topological order.
-- NOTE: result does not include the argument file.
getDependenciesRule :: Rules ()
getDependenciesRule =
    defineEarlyCutoff $ \GetDependencies file -> do
        depInfo <- use_ GetDependencyInformation file
        let allFiles = reachableModules depInfo
        _ <- uses_ ReportImportCycles allFiles
        opts <- getIdeOptions
        let mbFingerprints = map (fingerprintString . fromNormalizedFilePath) allFiles <$ optShakeFiles opts
        return (fingerprintToBS . fingerprintFingerprints <$> mbFingerprints, ([], transitiveDeps depInfo file))

getHieAstsRule :: Rules ()
getHieAstsRule =
    define $ \GetHieAst f -> do
      tmr <- use_ TypeCheck f
      hsc <- hscEnv <$> use_ GhcSession f
      getHieAstRuleDefinition f hsc tmr

getHieAstRuleDefinition :: NormalizedFilePath -> HscEnv -> TcModuleResult -> Action (IdeResult HieAstResult)
getHieAstRuleDefinition f hsc tmr = do
  (diags, masts) <- liftIO $ generateHieAsts hsc tmr
 
  isFoi <- use_ IsFileOfInterest f
  diagsWrite <- case isFoi of
    IsFOI Modified -> pure []
    _ | Just asts <- masts -> do
          source <- getSourceFileSource f
          liftIO $ writeHieFile hsc (tmrModSummary tmr) (tcg_exports $ tmrTypechecked tmr) asts source
    _ -> pure []
 
  im <- use GetLocatedImports f
  let mkImports (fileImports, _) = M.fromList $ mapMaybe (\(m, mfp) -> (unLoc m,) . artifactFilePath <$> mfp)  fileImports
 
  let refmap = generateReferencesMap . getAsts <$> masts
  pure (diags ++ diagsWrite, HAR (ms_mod  $ tmrModSummary tmr) <$> masts <*> refmap <*> fmap mkImports im)

getBindingsRule :: Rules ()
getBindingsRule =
  define $ \GetBindings f -> do
    har <- use_ GetHieAst f
    pure ([], Just $ bindings $ refMap har)

getDocMapRule :: Rules ()
getDocMapRule =
    define $ \GetDocMap file -> do
      hmi <- hirHomeMod <$> use_ GetModIface file
      hsc <- hscEnv <$> use_ GhcSessionDeps file
      (refMap -> rf) <- use_ GetHieAst file

-- When possible, rely on the haddocks embedded in our interface files
-- This creates problems on ghc-lib, see comment on 'getDocumentationTryGhc'
#if !defined(GHC_LIB)
      let parsedDeps = []
#else
      deps <- maybe (TransitiveDependencies [] [] []) fst <$> useWithStale GetDependencies file
      let tdeps = transitiveModuleDeps deps
      parsedDeps <- uses_ GetParsedModule tdeps
#endif

      dkMap <- liftIO $ evalGhcEnv hsc $ mkDocMap parsedDeps rf hmi
      return ([],Just dkMap)

-- Typechecks a module.
typeCheckRule :: Rules ()
typeCheckRule = define $ \TypeCheck file -> do
    pm <- use_ GetParsedModule file
    hsc  <- hscEnv <$> use_ GhcSessionDeps file
    typeCheckRuleDefinition hsc pm

knownFilesRule :: Rules ()
knownFilesRule = defineEarlyCutOffNoFile $ \GetKnownTargets -> do
  alwaysRerun
  fs <- knownTargets
  pure (BS.pack (show $ hash fs), unhashed fs)

getModuleGraphRule :: Rules ()
getModuleGraphRule = defineNoFile $ \GetModuleGraph -> do
  fs <- toKnownFiles <$> useNoFile_ GetKnownTargets
  rawDepInfo <- rawDependencyInformation (HashSet.toList fs)
  pure $ processDependencyInformation rawDepInfo

-- This is factored out so it can be directly called from the GetModIface
-- rule. Directly calling this rule means that on the initial load we can
-- garbage collect all the intermediate typechecked modules rather than
-- retain the information forever in the shake graph.
typeCheckRuleDefinition
    :: HscEnv
    -> ParsedModule
    -> Action (IdeResult TcModuleResult)
typeCheckRuleDefinition hsc pm = do
  setPriority priorityTypeCheck
  IdeOptions { optDefer = defer } <- getIdeOptions
  addUsageDependencies $ fmap (second (fmap snd)) $ liftIO $
    typecheckModule defer hsc pm
  where
    addUsageDependencies :: Action (a, Maybe TcModuleResult) -> Action (a, Maybe TcModuleResult)
    addUsageDependencies a = do
      r@(_, mtc) <- a
      forM_ mtc $ \tc -> do
        used_files <- liftIO $ readIORef $ tcg_dependent_files $ tmrTypechecked tc
        void $ uses_ GetModificationTime (map toNormalizedFilePath' used_files)
      return r

-- A local rule type to get caching. We want to use newCache, but it has
-- thread killed exception issues, so we lift it to a full rule.
-- https://github.com/digital-asset/daml/pull/2808#issuecomment-529639547
type instance RuleResult GhcSessionIO = IdeGhcSession

data GhcSessionIO = GhcSessionIO deriving (Eq, Show, Typeable, Generic)
instance Hashable GhcSessionIO
instance NFData   GhcSessionIO
instance Binary   GhcSessionIO

loadGhcSession :: Rules ()
loadGhcSession = do
    -- This function should always be rerun because it tracks changes
    -- to the version of the collection of HscEnv's.
    defineEarlyCutOffNoFile $ \GhcSessionIO -> do
        alwaysRerun
        opts <- getIdeOptions
        res <- optGhcSession opts

        let fingerprint = hash (sessionVersion res)
        return (BS.pack (show fingerprint), res)

    defineEarlyCutoff $ \GhcSession file -> do
        IdeGhcSession{loadSessionFun} <- useNoFile_ GhcSessionIO
        (val,deps) <- liftIO $ loadSessionFun $ fromNormalizedFilePath file

        -- add the deps to the Shake graph
        let addDependency fp = do
                let nfp = toNormalizedFilePath' fp
                itExists <- getFileExists nfp
                when itExists $ void $ use_ GetModificationTime nfp
        mapM_ addDependency deps

        opts <- getIdeOptions
        let cutoffHash =
              case optShakeFiles opts of
                -- optShakeFiles is only set in the DAML case.
                -- https://github.com/digital-asset/ghcide/pull/522#discussion_r428622915
                Just {} -> ""
                -- Hash the HscEnvEq returned so cutoff if it didn't change
                -- from last time
                Nothing -> BS.pack (show (hash (snd val)))
        return (Just cutoffHash, val)

    define $ \GhcSessionDeps file -> ghcSessionDepsDefinition file

ghcSessionDepsDefinition :: NormalizedFilePath -> Action (IdeResult HscEnvEq)
ghcSessionDepsDefinition file = do
        hsc <- hscEnv <$> use_ GhcSession file
        (deps,_) <- useWithStale_ GetDependencies file
        let tdeps = transitiveModuleDeps deps
        ifaces <- uses_ GetModIface tdeps

        -- Currently GetDependencies returns things in topological order so A comes before B if A imports B.
        -- We need to reverse this as GHC gets very unhappy otherwise and complains about broken interfaces.
        -- Long-term we might just want to change the order returned by GetDependencies
        let inLoadOrder = reverse (map hirHomeMod ifaces)

        (session',_) <- liftIO $ runGhcEnv hsc $ do
            setupFinderCache (map hirModSummary ifaces)
            mapM_ loadDepModule inLoadOrder

        res <- liftIO $ newHscEnvEq "" session' []
        return ([], Just res)

getModIfaceFromDiskRule :: Rules ()
getModIfaceFromDiskRule = defineEarlyCutoff $ \GetModIfaceFromDisk f -> do
  ms <- use_ GetModSummary f
  (diags_session, mb_session) <- ghcSessionDepsDefinition f
  case mb_session of
      Nothing -> return (Nothing, (diags_session, Nothing))
      Just session -> do
        sourceModified <- use_ IsHiFileStable f
        needsObj <- use_ NeedsObjectCode f
        r <- loadInterface (hscEnv session) ms sourceModified needsObj (regenerateHiFile session f)
        case r of
            (diags, Just x) -> do
                let fp = Just (hiFileFingerPrint x)
                return (fp, (diags <> diags_session, Just x))
            (diags, Nothing) -> return (Nothing, (diags ++ diags_session, Nothing))

isHiFileStableRule :: Rules ()
isHiFileStableRule = define $ \IsHiFileStable f -> do
    ms <- use_ GetModSummaryWithoutTimestamps f
    let hiFile = toNormalizedFilePath'
                $ ml_hi_file $ ms_location ms
    mbHiVersion <- use  GetModificationTime_{missingFileDiagnostics=False} hiFile
    modVersion  <- use_ GetModificationTime f
    sourceModified <- case mbHiVersion of
        Nothing -> pure SourceModified
        Just x ->
            if modificationTime x < modificationTime modVersion
                then pure SourceModified
                else do
                    (fileImports, _) <- use_ GetLocatedImports f
                    let imports = fmap artifactFilePath . snd <$> fileImports
                    deps <- uses_ IsHiFileStable (catMaybes imports)
                    pure $ if all (== SourceUnmodifiedAndStable) deps
                        then SourceUnmodifiedAndStable
                        else SourceUnmodified
    return ([], Just sourceModified)

getModSummaryRule :: Rules ()
getModSummaryRule = do
    defineEarlyCutoff $ \GetModSummary f -> do
        session <- hscEnv <$> use_ GhcSession f
        let dflags = hsc_dflags session
        (modTime, mFileContent) <- getFileContents f
        let fp = fromNormalizedFilePath f
        modS <- liftIO $ evalWithDynFlags dflags $ runExceptT $
                getModSummaryFromImports session fp modTime (textToStringBuffer <$> mFileContent)
        case modS of
            Right ms -> do
                let fingerPrint = hash (computeFingerprint f dflags ms, hashUTC modTime)
                return ( Just (BS.pack $ show fingerPrint) , ([], Just ms))
            Left diags -> return (Nothing, (diags, Nothing))

    defineEarlyCutoff $ \GetModSummaryWithoutTimestamps f -> do
        ms <- use GetModSummary f
        case ms of
            Just msWithTimestamps -> do
                let ms = msWithTimestamps { ms_hs_date = error "use GetModSummary instead of GetModSummaryWithoutTimestamps" }
                dflags <- hsc_dflags . hscEnv <$> use_ GhcSession f
                -- include the mod time in the fingerprint
                let fp = BS.pack $ show $ hash (computeFingerprint f dflags ms)
                return (Just fp, ([], Just ms))
            Nothing -> return (Nothing, ([], Nothing))
    where
        -- Compute a fingerprint from the contents of `ModSummary`,
        -- eliding the timestamps and other non relevant fields.
        computeFingerprint f dflags ModSummary{..} =
            let fingerPrint =
                    ( moduleNameString (moduleName ms_mod)
                    , ms_hspp_file
                    , map unLoc opts
                    , ml_hs_file ms_location
                    , fingerPrintImports ms_srcimps
                    , fingerPrintImports ms_textual_imps
                    )
                fingerPrintImports = map (fmap uniq *** (moduleNameString . unLoc))
                opts = Hdr.getOptions dflags (fromJust ms_hspp_buf) (fromNormalizedFilePath f)
            in fingerPrint

        hashUTC UTCTime{..} = (fromEnum utctDay, fromEnum utctDayTime)


generateCore :: RunSimplifier -> NormalizedFilePath -> Action (IdeResult ModGuts)
generateCore runSimplifier file = do
    packageState <- hscEnv <$> use_ GhcSessionDeps file
    tm <- use_ TypeCheck file
    setPriority priorityGenerateCore
    liftIO $ compileModule runSimplifier packageState (tmrModSummary tm) (tmrTypechecked tm)

generateCoreRule :: Rules ()
generateCoreRule =
    define $ \GenerateCore -> generateCore (RunSimplifier True)

getModIfaceRule :: Rules ()
getModIfaceRule = defineEarlyCutoff $ \GetModIface f -> do
#if !defined(GHC_LIB)
  fileOfInterest <- use_ IsFileOfInterest f
  case fileOfInterest of
    IsFOI status -> do
      -- Never load from disk for files of interest
      tmr <- use_ TypeCheck f
      needsObj <- use_ NeedsObjectCode f
      hsc <- hscEnv <$> use_ GhcSessionDeps f
      let compile = fmap ([],) $ use GenerateCore f
      (diags, !hiFile) <- compileToObjCodeIfNeeded hsc needsObj compile tmr
      let fp = hiFileFingerPrint <$> hiFile
      hiDiags <- case hiFile of
        Just hiFile
          | OnDisk <- status
          , not (tmrDeferedError tmr) -> liftIO $ writeHiFile hsc hiFile
        _ -> pure []
      return (fp, (diags++hiDiags, hiFile))
    NotFOI -> do
      hiFile <- use_ GetModIfaceFromDisk f
      let fp = hiFileFingerPrint hiFile
      return (Just fp, ([], Just hiFile))
#else
    tm <- use_ TypeCheck f
    hsc <- hscEnv <$> use_ GhcSessionDeps f
    (diags, !hiFile) <- liftIO $ compileToObjCodeIfNeeded hsc False (error "can't compile with ghc-lib") tm
    let fp = hiFileFingerPrint <$> hiFile
    return (fp, (diags, hiFile))
#endif

regenerateHiFile :: HscEnvEq -> NormalizedFilePath -> Bool -> Action ([FileDiagnostic], Maybe HiFileResult)
regenerateHiFile sess f objNeeded = do
    let hsc = hscEnv sess
        -- After parsing the module remove all package imports referring to
        -- these packages as we have already dealt with what they map to.
        comp_pkgs = mapMaybe (fmap fst . mkImportDirs (hsc_dflags hsc)) (deps sess)
    opt <- getIdeOptions
    (modTime, contents) <- getFileContents f

    -- Embed haddocks in the interface file
    (_, (diags, mb_pm)) <- liftIO $ getParsedModuleDefinition (withOptHaddock hsc) opt comp_pkgs f modTime contents
    (diags, mb_pm) <- case mb_pm of
        Just _ -> return (diags, mb_pm)
        Nothing -> do
            -- if parsing fails, try parsing again with Haddock turned off
            (_, (diagsNoHaddock, mb_pm)) <- liftIO $ getParsedModuleDefinition hsc opt comp_pkgs f modTime contents
            return (mergeParseErrorsHaddock diagsNoHaddock diags, mb_pm)
    case mb_pm of
        Nothing -> return (diags, Nothing)
        Just pm -> do
            -- Invoke typechecking directly to update it without incurring a dependency
            -- on the parsed module and the typecheck rules
            (diags', mtmr) <- typeCheckRuleDefinition hsc pm
            case mtmr of
              Nothing -> pure (diags', Nothing)
              Just tmr -> do

                -- compile writes .o file
                let compile = compileModule (RunSimplifier True) hsc (pm_mod_summary pm) $ tmrTypechecked tmr

                -- Bang pattern is important to avoid leaking 'tmr'
                (diags'', !res) <- liftIO $ compileToObjCodeIfNeeded hsc objNeeded compile tmr

                -- Write hi file
                hiDiags <- case res of
                  Just hiFile
                    | not $ tmrDeferedError tmr ->
                      liftIO $ writeHiFile hsc hiFile
                  _ -> pure []

                -- Write hie file
                (gDiags, masts) <- liftIO $ generateHieAsts hsc tmr
                wDiags <- forM masts $ \asts ->
                  liftIO $ writeHieFile hsc (tmrModSummary tmr) (tcg_exports $ tmrTypechecked tmr) asts $ maybe "" T.encodeUtf8 contents

                return (diags <> diags' <> diags'' <> hiDiags <> gDiags <> concat wDiags, res)


type CompileMod m = m (IdeResult ModGuts)

-- | HscEnv should have deps included already
compileToObjCodeIfNeeded :: MonadIO m => HscEnv -> Bool -> CompileMod m -> TcModuleResult -> m (IdeResult HiFileResult)
compileToObjCodeIfNeeded hsc False _ tmr = liftIO $ do
  res <- mkTcModuleResultNoCompile hsc tmr
  pure ([], Just $! res)
compileToObjCodeIfNeeded hsc True getGuts tmr = do
  (diags, mguts) <- getGuts
  case mguts of
    Nothing -> pure (diags, Nothing)
    Just guts -> do
      (diags', !res) <- liftIO $ mkTcModuleResultCompile hsc tmr guts
      pure (diags++diags', res)

getClientSettingsRule :: Rules ()
getClientSettingsRule = defineEarlyCutOffNoFile $ \GetClientSettings -> do
  alwaysRerun
  settings <- clientSettings <$> getIdeConfiguration
  return (BS.pack . show . hash $ settings, settings)

needsObjectCodeRule :: Rules ()
needsObjectCodeRule = defineEarlyCutoff $ \NeedsObjectCode file -> do
  (ms,_) <- useWithStale_ GetModSummaryWithoutTimestamps file
  -- A file needs object code if it uses TH or any file that depends on it uses TH
  res <-
    if uses_th_qq ms
    then pure True
    -- Treat as False if some reverse dependency header fails to parse
    else anyM (fmap (fromMaybe False) . use NeedsObjectCode) . maybe [] (immediateReverseDependencies file)
           =<< useNoFile GetModuleGraph
  pure (Just $ BS.pack $ show $ hash res, ([], Just res))
  where
    uses_th_qq (ms_hspp_opts -> dflags) =
      xopt LangExt.TemplateHaskell dflags || xopt LangExt.QuasiQuotes dflags

-- | A rule that wires per-file rules together
mainRule :: Rules ()
mainRule = do
    getParsedModuleRule
    getLocatedImportsRule
    getDependencyInformationRule
    reportImportCyclesRule
    getDependenciesRule
    typeCheckRule
    getDocMapRule
    loadGhcSession
    getModIfaceFromDiskRule
    getModIfaceRule
    getModSummaryRule
    isHiFileStableRule
    getModuleGraphRule
    knownFilesRule
    getClientSettingsRule
    getHieAstsRule
    getBindingsRule
    needsObjectCodeRule
    generateCoreRule

-- | Given the path to a module src file, this rule returns True if the
-- corresponding `.hi` file is stable, that is, if it is newer
--   than the src file, and all its dependencies are stable too.
data IsHiFileStable = IsHiFileStable
    deriving (Eq, Show, Typeable, Generic)
instance Hashable IsHiFileStable
instance NFData   IsHiFileStable
instance Binary   IsHiFileStable

type instance RuleResult IsHiFileStable = SourceModified
