{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Hyperion.Config where

import Data.Text              qualified as T
import Data.Time.Clock        (NominalDiffTime)
import Data.Time.Format       (defaultTimeLocale, formatTime)
import Data.Time.LocalTime    (getZonedTime)
import Hyperion.Log           qualified as Log
import Hyperion.ProgramId
import Hyperion.Remote        (HostNameStrategy, defaultHostNameStrategy)
import Hyperion.Slurm         qualified as Slurm
import Hyperion.WorkerCpuPool (CommandTransport, defaultCommandTransport)
import System.Directory       (copyFile, createDirectoryIfMissing)
import System.FilePath.Posix  (takeBaseName, takeDirectory, (<.>), (</>))

-- | Global configuration
data HyperionConfig = HyperionConfig
  { -- | Default options to use for @sbatch@ submissions
    defaultSbatchOptions :: Slurm.SbatchOptions
  , -- | Maximum number of jobs to submit at a time
    maxSlurmJobs         :: Maybe Int
    -- | Base directory for working dirs produced by 'newWorkDir'
  , dataDir              :: FilePath
    -- | Base directory for all the log files
  , logDir               :: FilePath
    -- | Base directory for databases
  , databaseDir          :: FilePath
    -- | Base directory for copies of the main executable
  , execDir              :: FilePath
    -- | Base directory for SLURM job files
  , jobDir               :: FilePath
    -- | The command to run the main executable. Automatic if 'Nothing' (see 'newClusterEnv')
  , hyperionCommand      :: Maybe FilePath
    -- | The database from which to initiate the program database
  , initialDatabase      :: Maybe FilePath
    -- | Email address for cluster notifications from
    -- hyperion. Nothing means no emails will be sent. Note that this
    -- setting can be different from the one in defaultSbatchOptions,
    -- which controls notifications from SLURM.
  , emailAddr            :: Maybe T.Text
  }

-- | Global static (compile-time) configuration. This is directly accessible to the master and to the workers
data HyperionStaticConfig = HyperionStaticConfig
  {
    -- | The command used to run shell commands on remtoe nodes in a job. Usually can be safely set to
    -- 'SSH Nothing'. See 'CommandTransport' for details.
    commandTransport           :: CommandTransport
    -- | The strategy for selecting our hostname. See 'HostNameStrategy' for details.
  , hostNameStrategy           :: HostNameStrategy
    -- | Timeout and number of retries for starting a node launcher on
    -- one of the nodes of a job.
  , nodeLauncherTimeoutRetries :: Maybe (NominalDiffTime, Int)
  }

-- | Default configuration, with all paths built form a single
-- 'baseDirectory'
defaultHyperionConfig :: FilePath -> HyperionConfig
defaultHyperionConfig baseDirectory = HyperionConfig
  { defaultSbatchOptions = Slurm.defaultSbatchOptions
  , maxSlurmJobs         = Nothing
  , dataDir              = baseDirectory </> "data"
  , logDir               = baseDirectory </> "logs"
  , databaseDir          = baseDirectory </> "databases"
  , execDir              = baseDirectory </> "executables"
  , jobDir               = baseDirectory </> "jobs"
  , hyperionCommand      = Nothing
  , initialDatabase      = Nothing
  , emailAddr            = Nothing
  }

defaultHyperionStaticConfig :: HyperionStaticConfig
defaultHyperionStaticConfig = HyperionStaticConfig
  { commandTransport           = defaultCommandTransport
  , hostNameStrategy           = defaultHostNameStrategy
  , nodeLauncherTimeoutRetries = Nothing
  }


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
