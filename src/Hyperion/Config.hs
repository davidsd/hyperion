{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Hyperion.Config where

import qualified Data.Text             as T
import           Data.Time.Format      (defaultTimeLocale, formatTime)
import           Data.Time.LocalTime   (getZonedTime)
import           Hyperion.Cluster
import qualified Hyperion.Database     as DB
import qualified Hyperion.Log          as Log
import           Hyperion.ProgramId
import           Hyperion.Slurm        (SbatchOptions)
import           Hyperion.Util         (savedExecutable)
import           System.Directory      (copyFile, createDirectoryIfMissing)
import           System.FilePath.Posix (takeBaseName, takeDirectory, (<.>),
                                        (</>))

data HyperionConfig = HyperionConfig
  { defaultSbatchOptions :: SbatchOptions
  , dataDir              :: FilePath
  , logDir               :: FilePath
  , databaseDir          :: FilePath
  , execDir              :: FilePath
  , hyperionCommand      :: Maybe FilePath
  , initialDatabase      :: Maybe FilePath
  , workerRetries        :: Int
  }

newClusterEnv :: HyperionConfig -> IO (ClusterEnv, FilePath)
newClusterEnv HyperionConfig{..} = do
  programId    <- newProgramId
  hyperionExec <- maybe
    (savedExecutable execDir (T.unpack (programIdToText programId)))
    return
    hyperionCommand
  programDatabase <- newDatabasePath initialDatabase databaseDir programId
  programLogDir <- timedProgramDir logDir programId
  programDataDir <- timedProgramDir dataDir programId
  let clusterJobOptions = defaultSbatchOptions
      clusterProgramInfo = ProgramInfo {..}
      clusterWorkerLauncher = slurmWorkerLauncher hyperionExec workerRetries
  clusterDatabasePool <- DB.newDefaultPool programDatabase
  return (ClusterEnv{..}, hyperionExec)

newDatabasePath :: Maybe FilePath -> FilePath -> ProgramId -> IO FilePath
newDatabasePath mOldDb baseDir progId = do
  let base = case mOldDb of
        Nothing -> ""
        Just f  -> takeBaseName f ++ "-"
  date <- formatTime defaultTimeLocale "%Y-%m" <$> getZonedTime
  let newDb = baseDir </> date </> (base ++ T.unpack (programIdToText progId)) <.> "sqlite"
  createDirectoryIfMissing True (takeDirectory newDb)
  case mOldDb of
    Nothing -> return ()
    Just f -> do
      Log.info "Copying database" (f, newDb)
      copyFile f newDb
  return newDb

timedProgramDir :: FilePath -> ProgramId -> IO FilePath
timedProgramDir baseDir progId = do
  date <- formatTime defaultTimeLocale "%Y-%m" <$> getZonedTime
  return $ baseDir </> date </> T.unpack (programIdToText progId)
