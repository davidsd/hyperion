{-# LANGUAGE DeriveAnyClass     #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings  #-}
{-# LANGUAGE RecordWildCards    #-}
{-# LANGUAGE StaticPointers     #-}
{-# LANGUAGE TypeFamilies       #-}

module Hyperion.Cluster where

import Control.Distributed.Process      (NodeId, Process)
import Control.Distributed.Process.Node (initRemoteTable)
import Control.Lens                     (lens)
import Control.Monad.Catch              (MonadCatch, try)
import Control.Monad.IO.Class           (MonadIO, liftIO)
import Control.Monad.Reader             (MonadReader, ReaderT, asks, runReaderT)
import Data.Aeson                       (FromJSON, ToJSON)
import Data.Binary                      (Binary)
import Data.Constraint                  (Dict (..))
import Data.Text                        (Text)
import Data.Text                        qualified as Text
import Data.Time.Clock                  (NominalDiffTime)
import Data.Typeable                    (Typeable)
import GHC.Generics                     (Generic)
import Hyperion.Command                 (hyperionWorkerCommand)
import Hyperion.Config                  (HyperionConfig (..),
                                         HyperionStaticConfig (..),
                                         newDatabasePath, timedProgramDir)
import Hyperion.Database                qualified as DB
import Hyperion.HasWorkers              (HasWorkerLauncher (..))
import Hyperion.HoldServer              (HoldMap, blockUntilRetried)
import Hyperion.LockMap                 (LockMap, newLockMap, registerLockMap)
import Hyperion.Log                     qualified as Log
import Hyperion.ObjectId                (getObjectId, objectIdToString)
import Hyperion.ProgramId               (ProgramId, newProgramId,
                                         programIdToText)
import Hyperion.Remote                  (runProcessLocalWithRT)
import Hyperion.Slurm                   (JobId (..), SbatchError,
                                         SbatchOptions (..), sbatchCommand)
import Hyperion.Slurm                   qualified as Slurm
import Hyperion.Static                  (Static (..), cPtr)
import Hyperion.TokenPool               (TokenPool, newTokenPool, withToken)
import Hyperion.Util                    (emailError, retryExponential,
                                         savedExecutable)
import Hyperion.Worker                  (RemoteError (..), ServiceId,
                                         WorkerLauncher (..),
                                         registerMasterNodeId,
                                         serviceIdToString, serviceIdToText)
import System.Directory                 (createDirectoryIfMissing)
import System.FilePath.Posix            ((<.>), (</>))

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
  { programId       :: ProgramId
  , programDatabase :: FilePath
  , programLogDir   :: FilePath
  , programDataDir  :: FilePath
  } deriving (Eq, Ord, Show, Generic, Binary, FromJSON, ToJSON)

instance Static (Binary ProgramInfo) where closureDict = cPtr (static Dict)

-- | The environment for 'Cluster' monad.
data ClusterEnv = ClusterEnv
  { clusterWorkerLauncher  :: SbatchOptions -> ProgramInfo -> WorkerLauncher JobId
  , clusterProgramInfo     :: ProgramInfo
  , clusterJobOptions      :: SbatchOptions
  , clusterDatabasePool    :: DB.Pool
  , clusterDatabaseRetries :: Int
  , clusterLockMap         :: LockMap
  , clusterStaticConfig    :: HyperionStaticConfig
  }

class HasProgramInfo a where
  toProgramInfo :: a -> ProgramInfo

instance HasProgramInfo ClusterEnv where
  toProgramInfo = clusterProgramInfo

-- | The 'Cluster' monad. It is simply 'Process' with 'ClusterEnv' environment.
type Cluster = ReaderT ClusterEnv Process

-- | 'ClusterEnv' is an instance of 'HasDB' since it contains info that is
-- sufficient to build a 'DB.DatabaseConfig'.
instance DB.HasDB ClusterEnv where
  dbConfigLens = lens get set
    where
      get ClusterEnv {..} = DB.DatabaseConfig
        { dbPool      = clusterDatabasePool
        , dbProgramId = programId clusterProgramInfo
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
  } deriving (Eq, Ord, Show, Generic, Binary, FromJSON, ToJSON, Typeable)

runCluster :: ClusterEnv -> Cluster a -> IO a
runCluster clusterEnv@ClusterEnv{..} h = runProcessLocalWithRT (hostNameStrategy clusterStaticConfig)
                                                               rtable (runReaderT h clusterEnv)
  where
    rtable = registerMasterNodeId Nothing
           $ registerLockMap clusterLockMap initRemoteTable

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

setSlurmConstraint :: Text -> ClusterEnv -> ClusterEnv
setSlurmConstraint c = modifyJobOptions $ \opts -> opts { constraint = Just c }

setSlurmAccount :: Text -> ClusterEnv -> ClusterEnv
setSlurmAccount a = modifyJobOptions $ \opts -> opts { account = Just a }

setSlurmQos :: Text -> ClusterEnv -> ClusterEnv
setSlurmQos a = modifyJobOptions $ \opts -> opts { qos = Just a }

-- | The default number of retries to use in 'withConnectionRetry'. Set to 20.
defaultDBRetries :: Int
defaultDBRetries = 20 -- update haddock if changing the value

dbConfigFromProgramInfo :: ProgramInfo -> IO DB.DatabaseConfig
dbConfigFromProgramInfo pInfo = do
  dbPool <- DB.newDefaultPool (programDatabase pInfo)
  let dbProgramId = programId pInfo
      dbRetries = defaultDBRetries
  return DB.DatabaseConfig{..}

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
newClusterEnv :: HyperionConfig -> HyperionStaticConfig -> HoldMap -> Int -> IO (ClusterEnv, FilePath)
newClusterEnv HyperionConfig{..} clusterStaticConfig holdMap holdPort = do
  programId    <- newProgramId
  hyperionExec <- maybe
    (savedExecutable execDir (Text.unpack (programIdToText programId)))
    return
    hyperionCommand
  programDatabase <- newDatabasePath initialDatabase databaseDir programId
  programLogDir <- timedProgramDir logDir programId
  programDataDir <- timedProgramDir dataDir programId
  sbatchTokenPool <- newTokenPool maxSlurmJobs
  let clusterJobOptions = defaultSbatchOptions { Slurm.chdir = Just jobDir }
      clusterProgramInfo = ProgramInfo {..}
      clusterWorkerLauncher = slurmWorkerLauncher emailAddr hyperionExec holdMap holdPort sbatchTokenPool
      clusterDatabaseRetries = defaultDBRetries
  clusterDatabasePool <- DB.newDefaultPool programDatabase
  clusterLockMap <- newLockMap
  return (ClusterEnv{..}, hyperionExec)

runDBWithProgramInfo :: ProgramInfo -> ReaderT DB.DatabaseConfig IO a -> IO a
runDBWithProgramInfo pInfo m = do
  dbConfigFromProgramInfo pInfo >>= runReaderT m

slurmWorkerLauncher
  :: Maybe Text      -- ^ Email address to send notifications to if sbatch
                     -- fails or there is an error in a remote
                     -- job. 'Nothing' means no emails will be sent.
  -> FilePath        -- ^ Path to this hyperion executable
  -> HoldMap         -- ^ HoldMap used by the HoldServer
  -> Int             -- ^ Port used by the HoldServer (needed for error messages)
  -> TokenPool       -- ^ TokenPool for throttling the number of submitted jobs
  -> SbatchOptions
  -> ProgramInfo
  -> WorkerLauncher JobId
slurmWorkerLauncher emailAddr hyperionExec holdMap holdPort sbatchTokenPool opts progInfo =
  WorkerLauncher {..}
  where
    connectionTimeout = Nothing

    emailAlertUser :: (MonadIO m, Show e) => e -> m ()
    emailAlertUser e = case emailAddr of
      Just toAddr -> emailError toAddr e
      Nothing     -> return ()

    onRemoteError :: forall b . RemoteError -> Process b -> Process b
    onRemoteError e@(RemoteError sId _) go = do
      let
        errInfo = (e, progInfo, msg)
        msg = mconcat
          [ "This remote process has been put on hold because of an error. "
          , "To retry it, run 'curl localhost:"
          , Text.pack (show holdPort)
          , "/retry/"
          , serviceIdToText sId
          , "'"
          ]
      Log.err errInfo
      emailAlertUser errInfo
      blockUntilRetried holdMap (serviceIdToText sId)
      Log.info "Retrying" sId
      go

    withLaunchedWorker :: forall b . NodeId -> ServiceId -> (JobId -> Process b) -> Process b
    withLaunchedWorker nid serviceId goJobId = withToken sbatchTokenPool $ do
      jobId <- liftIO $
        -- Repeatedly run sbatch, with exponentially increasing time
        -- intervals between failures. Email the user on each failure
        -- (see logSbatchError). We do not allow an SbatchError to
        -- propagate up from here because there is no obvious way to
        -- recover. TODO: maybe use the HoldServer?
        retryExponential (try @IO @SbatchError) logSbatchError $
        sbatchCommand opts' cmd (map Text.pack args)
      goJobId jobId
      where
        progId = programId progInfo
        logFile = programLogDir progInfo </> serviceIdToString serviceId <.> "log"
        opts' = opts
          { jobName = Just $ programIdToText progId <> "-" <> serviceIdToText serviceId
          }
        (cmd, args) = hyperionWorkerCommand hyperionExec nid serviceId logFile
        logSbatchError e = do
          Log.err e
          emailAlertUser (e, progInfo, nid, serviceId)

-- | Construct a working directory for the given object, using its
-- ObjectId. Will be a subdirectory of 'programDataDir'. Created
-- automatically, and saved in the database.
newWorkDir
  :: ( Binary a
     , Typeable a
     , ToJSON a
     , HasProgramInfo env
     , DB.HasDB env
     , MonadReader env m
     , MonadIO m
     , MonadCatch m
     )
  => a -> m FilePath
newWorkDir = DB.memoizeWithMap (DB.KeyValMap "workDirectories") $ \obj -> do
  dataDir <- asks (programDataDir . toProgramInfo)
  objId <- getObjectId obj
  let workDir = dataDir </> objectIdToString objId
  liftIO $ createDirectoryIfMissing True workDir
  return workDir
