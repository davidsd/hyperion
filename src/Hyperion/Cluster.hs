{-# LANGUAGE DeriveAnyClass             #-}
{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE DerivingStrategies         #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE TypeFamilies               #-}

module Hyperion.Cluster where

import           Control.Distributed.Process
import           Control.Lens                (lens)
import           Control.Monad.Reader
import           Data.Aeson                  (FromJSON, ToJSON)
import           Data.Binary                 (Binary)
import           Data.Data                   (Data)
import           Data.Monoid                 ((<>))
import           Data.Text                   (Text)
import qualified Data.Text                   as T
import           Data.Time.Clock             (NominalDiffTime)
import           GHC.Generics                (Generic)
import           Hyperion.Command            (hyperionWorkerCommand)
import qualified Hyperion.Database           as DB
import           Hyperion.HasWorkers         (HasWorkerLauncher (..))
import           Hyperion.ProgramId
import           Hyperion.Remote
import           Hyperion.Slurm              (JobId (..), SbatchOptions (..),
                                              sbatchCommand)
import           Hyperion.Util               (hashTruncateFileName,
                                              randomString, sanitizeFileString)
import           System.Directory            (createDirectoryIfMissing)
import           System.FilePath.Posix       ((<.>), (</>))

data ProgramInfo = ProgramInfo
  { programId       :: ProgramId
  , programDatabase :: FilePath
  , programLogDir   :: FilePath
  , programDataDir  :: FilePath
  } deriving (Eq, Generic, Data, Binary, FromJSON, ToJSON)

data ClusterEnv = ClusterEnv
  { clusterWorkerLauncher :: SbatchOptions -> ProgramInfo -> WorkerLauncher JobId
  , clusterProgramInfo    :: ProgramInfo
  , clusterJobOptions     :: SbatchOptions
  , clusterDatabasePool   :: DB.Pool
  }

type Cluster = ReaderT ClusterEnv Process

instance DB.HasDB ClusterEnv where
  dbConfigLens = lens get set
    where
      get ClusterEnv {..} = DB.DatabaseConfig
        { DB.dbPool         = clusterDatabasePool
        , DB.dbProgramId    = programId (clusterProgramInfo)
        }
      set h DB.DatabaseConfig {..} = h
        { clusterDatabasePool = dbPool
        , clusterProgramInfo  = (clusterProgramInfo h)
          { programId = dbProgramId }
        }

instance HasWorkerLauncher ClusterEnv where
  toWorkerLauncher ClusterEnv{..} =
    clusterWorkerLauncher clusterJobOptions clusterProgramInfo

data MPIJob = MPIJob
  { mpiNodes         :: Int
  , mpiNTasksPerNode :: Int
  } deriving (Show)

runCluster :: ClusterEnv -> Cluster a -> IO a
runCluster clusterEnv h = do
  runProcessLocallyDefault (runReaderT h clusterEnv)

clusterProgramId :: ClusterEnv -> ProgramId
clusterProgramId = programId . clusterProgramInfo

clusterProgramDatabase :: ClusterEnv  -> FilePath
clusterProgramDatabase = programDatabase . clusterProgramInfo

modifyJobOptions :: (SbatchOptions -> SbatchOptions) -> ClusterEnv -> ClusterEnv
modifyJobOptions f cfg = cfg { clusterJobOptions = f (clusterJobOptions cfg) }

setJobOptions :: SbatchOptions -> ClusterEnv -> ClusterEnv
setJobOptions c = modifyJobOptions (const c)

setJobTime :: NominalDiffTime -> ClusterEnv -> ClusterEnv
setJobTime t = modifyJobOptions $ \opts -> opts { time = t }

setJobMemory :: Text -> ClusterEnv -> ClusterEnv
setJobMemory m = modifyJobOptions $ \opts -> opts { mem = Just m }

setJobType :: MPIJob -> ClusterEnv -> ClusterEnv
setJobType MPIJob{..} = modifyJobOptions $ \opts -> opts
  { nodes = mpiNodes
  , nTasksPerNode = mpiNTasksPerNode
  }

setSlurmPartition :: Text -> ClusterEnv -> ClusterEnv
setSlurmPartition p = modifyJobOptions $ \opts -> opts { partition = Just p }

dbConfigFromProgramInfo :: ProgramInfo -> IO DB.DatabaseConfig
dbConfigFromProgramInfo pInfo = do
  dbPool <- DB.newDefaultPool (programDatabase pInfo)
  let dbProgramId = programId pInfo
  return DB.DatabaseConfig{..}

runDBWithProgramInfo :: ProgramInfo -> ReaderT DB.DatabaseConfig IO a -> IO a
runDBWithProgramInfo pInfo m = do
  dbConfigFromProgramInfo pInfo >>= runReaderT m

slurmWorkerLauncher
  :: FilePath
  -> Int
  -> SbatchOptions
  -> ProgramInfo
  -> WorkerLauncher JobId
slurmWorkerLauncher hyperionExec workerRetries opts progInfo =
  WorkerLauncher {..}
  where
    connectionTimeout = Nothing
    withLaunchedWorker :: forall b . NodeId -> ServiceId -> (JobId -> Process b) -> Process b
    withLaunchedWorker nodeId serviceId goJobId = do
      let progId = programId progInfo
          logFile = programLogDir progInfo </> "workers" </> serviceIdToString serviceId <.> "log"
      let opts' = opts
            { jobName = Just $ programIdToText progId <> "-" <> serviceIdToText serviceId
            }
          (cmd, args) = hyperionWorkerCommand hyperionExec nodeId serviceId logFile
      jobId <- liftIO $ sbatchCommand opts' cmd (map T.pack args)
      goJobId jobId

-- Generate a working directory for the given object. Working
-- directories are (essentially) unique for each call to this
-- function, due to the use of 'salt'.
--
-- workDir path's have are length-truncated at 230 (see Util.hs),
-- allowing up to 25 additional characters for file extensions.
newWorkDir :: Show a => a -> Cluster FilePath
newWorkDir obj = do
  dataDir <- asks (programDataDir . clusterProgramInfo)
  salt <- liftIO $ randomString 4
  let slug = sanitizeFileString (filter (/= ' ') (show obj))
      base = hashTruncateFileName (slug <> "-" <> salt)
      workDir = dataDir </> base
  liftIO $ createDirectoryIfMissing True workDir
  return workDir

-- A memoized version of newWorkDir that saves the result to the
-- database
newWorkDirPersistent :: (ToJSON a, Show a) => a -> Cluster FilePath
newWorkDirPersistent = DB.memoizeWithMap (DB.KeyValMap "workDirectories") newWorkDir
