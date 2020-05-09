{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Hyperion.Config where

import qualified Data.Text              as T
import           Data.Time.Format       (defaultTimeLocale, formatTime)
import           Data.Time.LocalTime    (getZonedTime)
import           Hyperion.Cluster
import qualified Hyperion.Database      as DB
import           Hyperion.HoldServer    (HoldMap, newHoldMap)
import qualified Hyperion.Log           as Log
import           Hyperion.ProgramId
import qualified Hyperion.Slurm         as Slurm
import           Hyperion.Util          (savedExecutable)
import           Hyperion.WorkerCpuPool (SSHCommand)
import           System.Directory       (copyFile, createDirectoryIfMissing)
import           System.FilePath.Posix  (takeBaseName, takeDirectory, (<.>),
                                         (</>))

-- | Global configuration for "Hyperion" cluster. 
data HyperionConfig = HyperionConfig
  { 
    -- | Default options to use for @sbatch@ submissions
    defaultSbatchOptions :: Slurm.SbatchOptions
    -- | The base directory for working dirs produced by 'newWorkDir'
  , dataDir              :: FilePath
    -- | The base directory for all the log files 
  , logDir               :: FilePath
    -- | The base directory for databases
  , databaseDir          :: FilePath
    -- | The base directory for copies of the main executable
  , execDir              :: FilePath
    -- | The command to run the main executable. Automatic if 'Nothing' (see 'newClusterEnv')
  , hyperionCommand      :: Maybe FilePath
    -- | The database from which to initiate the program database
  , initialDatabase      :: Maybe FilePath
    -- | The command used to run @ssh@ on nodes. Usually can be safely set to
    -- 'Nothing'. See 'SSHCommand' for details.
  , sshRunCommand        :: SSHCommand
  }

-- | Default configuration, with all paths built form a single
-- 'baseDirectory'
defaultHyperionConfig :: FilePath -> HyperionConfig
defaultHyperionConfig baseDirectory = HyperionConfig
  { defaultSbatchOptions = Slurm.defaultSbatchOptions
  , dataDir              = baseDirectory </> "data"
  , logDir               = baseDirectory </> "log"
  , databaseDir          = baseDirectory </> "database"
  , execDir              = baseDirectory </> "exec"
  , hyperionCommand      = Nothing
  , initialDatabase      = Nothing
  , sshRunCommand        = Nothing
  }

-- | Takes 'HyperionConfig' and returns 'ClusterEnv', the path to the executable,
-- and a new 'HoldMap.
--
-- Things to note: 
--
--     * 'programId' is generated randomly.
--     * If 'hyperionCommand' is specified in 'HyperionConfig', then
--       'hyperionExec' == 'hyperionCommand'. Otherwise the running executable 
--       is copied to 'execDir' with a unique name, and that is used as 'hyperionExec'.
--     * 'newDatabasePath' is used to determine 'programDatabase' from 'initialDatabase'
--       and 'databaseDir', 'programId'.
--     * 'timedProgramDir' is used to determine 'programLogDir' and 'programDataDir' 
--       from the values in 'HyperionConfig' and 'programId'.
--     * 'slurmWorkerLauncher' is used for 'clusterWorkerLauncher'
--     * 'clusterDatabaseRetries' is set to 'defaultDBRetries'.
newClusterEnv :: HyperionConfig -> IO (ClusterEnv, FilePath, HoldMap)
newClusterEnv HyperionConfig{..} = do
  programId    <- newProgramId
  hyperionExec <- maybe
    (savedExecutable execDir (T.unpack (programIdToText programId)))
    return
    hyperionCommand
  programDatabase <- newDatabasePath initialDatabase databaseDir programId
  programLogDir <- timedProgramDir logDir programId
  programDataDir <- timedProgramDir dataDir programId
  holdMap <- newHoldMap
  let clusterJobOptions = defaultSbatchOptions
      programSSHCommand = sshRunCommand
      clusterProgramInfo = ProgramInfo {..}
      clusterWorkerLauncher = slurmWorkerLauncher hyperionExec holdMap
      clusterDatabaseRetries = defaultDBRetries
  clusterDatabasePool <- DB.newDefaultPool programDatabase
  return (ClusterEnv{..}, hyperionExec, holdMap)

-- | Returns the path to a new database, given 'Maybe' inital database filepath
-- and base directory
--
-- If 'ProgramId' id is @XXXXX@ and initial database filename is @original.sqlite@,
-- then the new filename is @original-XXXXX.sqlite@. If initial database path is
-- 'Nothing', then the filename is @XXXXX.sqlite@.
--
-- The path is in subdirectory @YYYY-mm@ (determined by current date) of base directory. 
--
-- If inital database is given, then the new database is initilized with its contents.
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

-- | Given base directory and 'ProgramId' (@==XXXXX@), returns the @YYYY-mm/XXXXX@ 
-- subdirectory of the base directory (determined by current date).
timedProgramDir :: FilePath -> ProgramId -> IO FilePath
timedProgramDir baseDir progId = do
  date <- formatTime defaultTimeLocale "%Y-%m" <$> getZonedTime
  return $ baseDir </> date </> T.unpack (programIdToText progId)
