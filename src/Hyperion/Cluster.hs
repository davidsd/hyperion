{-# LANGUAGE DeriveAnyClass             #-}
{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE DerivingStrategies         #-}
{-# LANGUAGE FlexibleInstances          #-}
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
import           Data.Hashable               (Hashable, hash)
import           Data.Text                   (Text)
import qualified Data.Text                   as Text
import           Data.Time.Clock             (NominalDiffTime)
import           GHC.Generics                (Generic)
import           Hyperion.Command            (hyperionWorkerCommand)
import qualified Hyperion.Database           as DB
import           Hyperion.HasWorkers         (HasWorkerLauncher (..))
import           Hyperion.HoldServer         (HoldMap)
import           Hyperion.ProgramId
import           Hyperion.Remote
import           Hyperion.Slurm              (JobId (..), SbatchOptions (..),
                                              sbatchCommand)
import           Hyperion.WorkerCpuPool      (SSHCommand)
import           System.Directory            (createDirectoryIfMissing)
import           System.FilePath.Posix       ((<.>), (</>))

-- * General comments
-- $
-- In this module we define the 'Cluster' monad. It is nothing more than a
-- 'Process' with an environment 'ClusterEnv'.
--
-- The 'ClusterEnv' environment contains information about
--
--     * the 'ProgramId' of the current run,
--     * the paths to database and log/data directories that we should use,
--     * options to use when using @sbatch@ to spawn cluster jobs,
--     * data equivalent to 'DB.DatabaseConfig' to handle the database,
--     * a 'WorkerLauncher' to launch remote workers. More precisely, a function
--       'clusterWorkerLauncher' that takes 'SbatchOptions' and 'ProgramInfo' to
--       produce a 'WorkerLauncher'.
--
-- A 'ClusterEnv' may be initialized with 'Hyperion.Config.newClusterEnv', which
-- use 'slurmWorkerLauncher' to initialize 'clusterWorkerLauncher'. In this
-- scenario the 'Cluster' monad will operate in the following way. It will perform
-- the calculations in the master process until some remote function is invoked,
-- typically through 'Hyperion.HasWorkers.remoteEval', at which point it will
-- use @sbatch@ and the current 'SbatchOptions' to allocate a new job and then
-- it will run a single worker in that allocation.
--
-- This has the following consequences.
--
--     * Each time 'Cluster' runs a remote function, it will schedule
--       a new job with @SLURM@. If you run a lot of small remote
--       functions (e.g., using "Hyperion.Concurrently") in 'Cluster'
--       monad, it means that you will schedule a lot of small jobs
--       with @SLURM@. If your cluster's scheduling prioritizes small
--       jobs, this may be a fine mode of operation (for example, this
--       was the case on the now-defunct @Hyperion@ cluster at IAS).
--       More likely though, it will lead to your jobs pending and the
--       computation running slowly, especially if the remote
--       functions are not run at the same time, but new ones are run
--       when old ones finish (for example, if you try to perform a
--       lot of parallel binary searches). For such cases
--       'Hyperion.Job.Job' monad should be used.
--     * One should use 'Hyperion.Slurm.Sbatch.nodes' greater than 1
--       if either: (1) The job runs an external program that uses MPI
--       or something similar and therefore can access all of the
--       resources allocated by @SLURM@, or (2) the remote function
--       spawns new @hyperion@ workers using the 'Job' monad.  If your
--       remote function does spawn new workers, then it may make
--       sense to use 'Hyperion.Slurm.Sbatch.nodes' greater than 1,
--       but your remote function needs to take into account the fact
--       that the nodes are already allocated. For example, from the
--       'Cluster' monad, we can run a remote computation in the
--       'Job', allocating it more than 1 node. The 'Job' computation
--       will automagically detect the nodes available to it, the
--       number of CPUs on each node, and will create a
--       'WorkerCpuPool' that will manage these resources
--       independently of @SLURM@. One can then run remote functions
--       on these resources from the 'Job' computation without having
--       to wait for @SLURM@ scheduling. See "Hyperion.Job" for
--       details.
--
-- The common usecase is that a 'Cluster' computation is ran on the login node.
-- It then schedules a job with a bunch or resources with @SLURM@. When the job
-- starts, a 'Job' calculation runs on one of the allocated nodes. It then spawns
-- 'Process' computations on the resources available to the job, which it manages
-- via 'Hyperion.WorkerCpuPool.WorkerCpuPool'.
--
-- Besides the 'Cluster' monad, this module defines 'slurmWorkerLauncher' and
-- some utility functions for working with 'ClusterEnv' and 'ProgramInfo', along
-- with a few others.


-- * Documentation
-- $

-- | Type containing information about our program
data ProgramInfo = ProgramInfo
  { programId         :: ProgramId
  , programDatabase   :: FilePath
  , programLogDir     :: FilePath
  , programDataDir    :: FilePath
  , programSSHCommand :: SSHCommand
  } deriving (Eq, Ord, Show, Generic, Data, Binary, FromJSON, ToJSON)

-- | The environment for 'Cluster' monad.
data ClusterEnv = ClusterEnv
  { clusterWorkerLauncher  :: SbatchOptions -> ProgramInfo -> WorkerLauncher JobId
  , clusterProgramInfo     :: ProgramInfo
  , clusterJobOptions      :: SbatchOptions
  , clusterDatabasePool    :: DB.Pool
  , clusterDatabaseRetries :: Int
  }

-- | The 'Cluster' monad. It is simply 'Process' with 'ClusterEnv' environment.
type Cluster = ReaderT ClusterEnv Process

-- | 'ClusterEnv' is an instance of 'HasDB' since it contains info that is
-- sufficient to build a 'DB.DatabaseConfig'.
instance DB.HasDB ClusterEnv where
  dbConfigLens = lens get set
    where
      get ClusterEnv {..} = DB.DatabaseConfig
        { dbPool      = clusterDatabasePool
        , dbProgramId = programId (clusterProgramInfo)
        , dbRetries   = clusterDatabaseRetries
        }
      set h DB.DatabaseConfig {..} = h
        { clusterDatabasePool    = dbPool
        , clusterProgramInfo     = (clusterProgramInfo h) { programId = dbProgramId }
        , clusterDatabaseRetries = dbRetries
        }

-- | We make 'ClusterEnv' an instance of 'HasWorkerLauncher'. This makes
-- 'Cluster' an instance of 'HasWorkers' and gives us access to functions in
-- "Hyperion.Remote".
instance HasWorkerLauncher ClusterEnv where
  toWorkerLauncher ClusterEnv{..} =
    clusterWorkerLauncher clusterJobOptions clusterProgramInfo

-- | Type representing resources for an MPI job.
data MPIJob = MPIJob
  { mpiNodes         :: Int
  , mpiNTasksPerNode :: Int
  } deriving (Eq, Ord, Show, Generic, Data, Binary, FromJSON, ToJSON, Hashable)

runCluster :: ClusterEnv -> Cluster a -> IO a
runCluster clusterEnv h = do
  runProcessLocallyDefault (runReaderT h clusterEnv)

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

-- | The default number of retries to use in 'withConnectionRetry'. Set to 20.
defaultDBRetries :: Int
defaultDBRetries = 20 -- update haddock if changing the value

dbConfigFromProgramInfo :: ProgramInfo -> IO DB.DatabaseConfig
dbConfigFromProgramInfo pInfo = do
  dbPool <- DB.newDefaultPool (programDatabase pInfo)
  let dbProgramId = programId pInfo
      dbRetries = defaultDBRetries
  return DB.DatabaseConfig{..}

runDBWithProgramInfo :: ProgramInfo -> ReaderT DB.DatabaseConfig IO a -> IO a
runDBWithProgramInfo pInfo m = do
  dbConfigFromProgramInfo pInfo >>= runReaderT m

slurmWorkerLauncher
  :: FilePath
  -> HoldMap
  -> SbatchOptions
  -> ProgramInfo
  -> WorkerLauncher JobId
slurmWorkerLauncher hyperionExec holdMap opts progInfo =
  WorkerLauncher {..}
  where
    connectionTimeout = Nothing
    serviceHoldMap = Just holdMap
    withLaunchedWorker :: forall b . NodeId -> ServiceId -> (JobId -> Process b) -> Process b
    withLaunchedWorker nodeId serviceId goJobId = do
      let progId = programId progInfo
          logFile = programLogDir progInfo </> "workers" </> serviceIdToString serviceId <.> "log"
      let opts' = opts
            { jobName = Just $ programIdToText progId <> "-" <> serviceIdToText serviceId
            }
          (cmd, args) = hyperionWorkerCommand hyperionExec nodeId serviceId logFile
      jobId <- liftIO $ sbatchCommand opts' cmd (map Text.pack args)
      goJobId jobId

-- | An identifier for an object, useful for building filenames and
-- database entries.
newtype ObjectId = ObjectId Int
  deriving (Eq, Ord, Generic, Data, Binary, FromJSON, ToJSON)

-- | Convert an ObjectId to a String. With the current implementation
-- of 'getObjectId', this string will contain only digits.
objectIdToString :: ObjectId -> String
objectIdToString (ObjectId i) = show i

-- | Convert an ObjectId to Text. With the current implementation
-- of 'getObjectId', this string will contain only digits.
objectIdToText :: ObjectId -> Text
objectIdToText = Text.pack . objectIdToString

-- | The ObjectId of an object is the absolute value of its hash. The
-- first time it is called on a given object, 'getObjectId' comptues
-- the ObjectId and stores it in the database before returning
-- it. Subsequent calls read the value from the database.
getObjectId :: (Hashable a, ToJSON a) => a -> Cluster ObjectId
getObjectId = DB.memoizeWithMap (DB.KeyValMap "objectIds") (pure . ObjectId . abs . hash)

-- | Construct a working directory for the given object, using its
-- ObjectId. Will be a subdirectory of 'programDataDir'. Created
-- automatically, and saved in the database.
newWorkDir :: (Hashable a, ToJSON a) => a -> Cluster FilePath
newWorkDir = DB.memoizeWithMap (DB.KeyValMap "workDirectories") $ \obj -> do
  dataDir <- asks (programDataDir . clusterProgramInfo)
  objId <- getObjectId obj
  let workDir = dataDir </> objectIdToString objId
  liftIO $ createDirectoryIfMissing True workDir
  return workDir
