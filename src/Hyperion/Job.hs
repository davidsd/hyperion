{-# LANGUAGE DeriveAnyClass     #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase         #-}
{-# LANGUAGE OverloadedStrings  #-}
{-# LANGUAGE RecordWildCards    #-}
{-# LANGUAGE StaticPointers     #-}
{-# LANGUAGE TypeFamilies       #-}

module Hyperion.Job where

import Control.Distributed.Process (NodeId, Process, spawnLocal)
import Control.Lens                (lens)
import Control.Monad.Catch         (throwM, try)
import Control.Monad.IO.Class      (MonadIO, liftIO)
import Control.Monad.Reader        (ReaderT, asks, runReaderT)
import Control.Monad.Trans         (lift)
import Control.Monad.Trans.Cont    (ContT (..), evalContT)
import Data.Binary                 (Binary)
import Data.Map                    qualified as Map
import Data.Maybe                  (catMaybes)
import Data.Text                   qualified as T
import Data.Typeable               (Typeable)
import Hyperion.Cluster            (Cluster, ClusterEnv (..),
                                    HasProgramInfo (..), ProgramInfo (..),
                                    dbConfigFromProgramInfo)
import Hyperion.Command            (hyperionWorkerCommand)
import Hyperion.Config             (HyperionStaticConfig (..))
import Hyperion.Database           qualified as DB
import Hyperion.HasWorkers         (HasWorkerLauncher (..), remoteEvalM)
import Hyperion.Log                qualified as Log
import Hyperion.Remote             (runProcessLocal)
import Hyperion.Slurm              (JobId (..))
import Hyperion.Slurm              qualified as Slurm
import Hyperion.Static             (Closure, Static (..), cAp, cPure)
import Hyperion.Util               (myExecutable, runCmdLocalAsync,
                                    runCmdLocalLog)
import Hyperion.Worker             (ServiceId, WorkerLauncher (..),
                                    getWorkerStaticConfig,
                                    mkSerializableClosureProcess,
                                    serviceIdToText, withRemoteRunProcess,
                                    worker)
import Hyperion.WorkerCpuPool      (CommandTransport, NumCPUs (..), SSHError,
                                    WorkerAddr)
import Hyperion.WorkerCpuPool      qualified as WCP
import System.FilePath.Posix       (dropExtension, (<.>), (</>))

-- * General comments
-- $
-- In this module we define the 'Job' monad. It is nothing more than 'Process'
-- together with 'JobEnv' environment.
--
-- The 'JobEnv' environment represents the environment of a job running under
-- @SLURM@. We should think about a computation in 'Job' as being run on a
-- node allocated for the job by @SLURM@ and running remote computations on the
-- resources allocated to the job. The 'JobEnv' environment
-- contains
--
--     * information about the master program that scheduled the job,
--     * information about the database used for recording results of the calculations,
--     * number of CPUs available per node, as well as the number of CPUs to
--       use for remote computations spawned from the 'Job' computation ('jobTaskCpus'),
--     * 'jobTaskLauncher', which allocates 'jobTaskCpus' CPUs on some node from
--       the resources available to the job and launches a worker on that node.
--       That worker is then allowed to use the allocated number of CPUs.
--       Thanks to 'jobTaskLauncher', 'Job' is an instance of 'Hyperion.Remote.HasWorkers' and
--       we can use functions such as 'Hyperion.Remote.remoteEval'.
--
-- The common usecase is that the 'Job' computation is spawned from a 'Cluster'
-- calculation on login node via, e.g., 'remoteEvalJob' (which acquires job
-- resources from @SLURM@). The 'Job' computation then manages the job resources
-- and runs remote computations in the allocation via, e.g., 'Hyperion.Remote.remoteEval'.

-- * Documentation
-- $

-- | The environment type for 'Job' monad.
data JobEnv = JobEnv
  {
    -- | 'DB.DatabaseConfig' for the database to use
    jobDatabaseConfig :: DB.DatabaseConfig
    -- | Number of CPUs available on each node in the job
  , jobNodeCpus       :: NumCPUs
    -- | Number of CPUs to use for running remote functions
  , jobTaskCpus       :: NumCPUs
    -- | 'ProgramInfo' inherited from the master
  , jobProgramInfo    :: ProgramInfo
    -- | a 'WorkerLauncher' that runs workers with the given number of CPUs allocated
  , jobTaskLauncher   :: NumCPUs -> WorkerLauncher JobId
    -- | The global static configuration
  , jobStaticConfig   :: HyperionStaticConfig
  }

instance HasProgramInfo JobEnv where
  toProgramInfo = jobProgramInfo

-- | Configuration for 'withNodeLauncher'.
data NodeLauncherConfig = NodeLauncherConfig
  {
    -- | The directory to which the workers shall log.
    nodeLogDir           :: FilePath
    -- | The command used to run shell commands on remote nodes. See 'CommandTransport' for description.
  , nodeCommandTransport :: CommandTransport
  }

-- | Make 'JobEnv' an instance of 'DB.HasDB'.
instance DB.HasDB JobEnv where
  dbConfigLens = lens get set
    where
      get = jobDatabaseConfig
      set cfg databaseConfig' = cfg { jobDatabaseConfig = databaseConfig' }

-- | Make 'JobEnv' an instance of 'HasWorkerLauncher'. The 'WorkerLauncher' returned
-- by 'toWorkerLauncher' launches workers with 'jobTaskCpus' CPUs available to them.
--
-- This makes 'Job' an instance of 'HasWorkers' and gives us access to functions in
-- "Hyperion.Remote".
instance HasWorkerLauncher JobEnv where
  toWorkerLauncher JobEnv{..} = jobTaskLauncher jobTaskCpus

-- | 'Job' monad is simply 'Process' with 'JobEnv' environment.
type Job = ReaderT JobEnv Process

-- | Changses 'jobTaskCpus' in 'JobEnv'
setTaskCpus :: NumCPUs -> JobEnv -> JobEnv
setTaskCpus n cfg = cfg { jobTaskCpus = n }

-- | Runs the 'Job' monad assuming we are inside a SLURM job. In
-- practice it just fills in the environment 'JobEnv' and calls
-- 'runReaderT'. The environment is mostly constructed from @SLURM@
-- environment variables and 'ProgramInfo'. The exceptions to these
-- are 'jobTaskCpus', which is set to @'NumCPUs' 1@, and
-- 'jobTaskLauncher', which is created by 'withPoolLauncher'.
-- The log file has the form \"\/a\/b\/c\/progid\/serviceid.log\"
-- . The log directory for the node is obtained by dropping
-- the .log extension: \"\/a\/b\/c\/progid\/serviceid\"
-- We are assuming that the remote table for 'Process' contains
-- the static configuration as initialized by 'initWorkerRemoteTable'
runJobSlurm :: ProgramInfo -> Job a -> Process a
runJobSlurm programInfo go = do
  dbConfig <- liftIO $ dbConfigFromProgramInfo programInfo
  nodes <- liftIO WCP.getSlurmAddrs
  nodeCpus <- liftIO Slurm.getNTasksPerNode
  maybeLogFile <- Log.getLogFile
  staticConfig <- getWorkerStaticConfig
  let
    nodeLauncherConfig = NodeLauncherConfig
      { nodeLogDir = case maybeLogFile of
          Just logFile -> dropExtension logFile
          -- Fallback case for when Log.currentLogFile has not been
          -- set. This should never happen.
          Nothing      -> programLogDir programInfo </> "workers" </> "workers"
      , nodeCommandTransport = commandTransport staticConfig
      }
  withPoolLauncher nodeLauncherConfig nodes $ \poolLauncher -> do
    let cfg = JobEnv
          { jobDatabaseConfig = dbConfig
          , jobNodeCpus       = NumCPUs nodeCpus
          , jobTaskCpus       = NumCPUs 1
          , jobTaskLauncher   = poolLauncher
          , jobProgramInfo    = programInfo
          , jobStaticConfig   = staticConfig
          }
    runReaderT go cfg

-- | Runs the 'Job' locally in IO without using any information from a
-- SLURM environment, with some basic default settings. This function
-- is provided primarily for testing.
runJobLocal :: HyperionStaticConfig -> ProgramInfo -> Job a -> IO a
runJobLocal staticConfig programInfo go = runProcessLocal (hostNameStrategy staticConfig) $ do
  dbConfig <- liftIO $ dbConfigFromProgramInfo programInfo
  let
    withLaunchedWorker :: forall b . NodeId -> ServiceId -> (JobId -> Process b) -> Process b
    withLaunchedWorker nid serviceId goJobId = do
      _ <- spawnLocal (worker nid serviceId)
      goJobId (JobName (serviceIdToText serviceId))
    connectionTimeout = Nothing
    onRemoteError e _ = throwM e
  runReaderT go $ JobEnv
    { jobDatabaseConfig = dbConfig
    , jobNodeCpus       = NumCPUs 1
    , jobTaskCpus       = NumCPUs 1
    , jobTaskLauncher   = const WorkerLauncher{..}
    , jobProgramInfo    = programInfo
    , jobStaticConfig   = staticConfig
    }

-- | 'WorkerLauncher' that uses the supplied command runner to launch
-- workers.  Sets 'connectionTimeout' to 'Nothing'. Uses the
-- 'ServiceId' supplied to 'withLaunchedWorker' to construct 'JobId'
-- (through 'JobName').  The supplied 'FilePath' is used as log
-- directory for the worker, with the log file name derived from
-- 'ServiceId'.
workerLauncherWithRunCmd
  :: MonadIO m
  => FilePath
  -> ((String, [String]) -> Process ())
  -> m (WorkerLauncher JobId)
workerLauncherWithRunCmd logDir runCmd = liftIO $ do
  hyperionExec <- myExecutable
  let
    withLaunchedWorker :: forall b . NodeId -> ServiceId -> (JobId -> Process b) -> Process b
    withLaunchedWorker nid serviceId goJobId = do
      let jobId = JobName (serviceIdToText serviceId)
          logFile = logDir </> T.unpack (serviceIdToText serviceId) <.> "log"
      runCmd (hyperionWorkerCommand hyperionExec nid serviceId logFile)
      goJobId jobId
    connectionTimeout = Nothing
    onRemoteError e _ = throwM e
  return WorkerLauncher{..}

-- | Given a `NodeLauncherConfig` and a 'WorkerAddr' runs the
-- continuation 'Maybe' passing it a pair @('WorkerAddr',
-- 'WorkerLauncher' 'JobId')@.  Passing 'Nothing' repersents a
-- command transport failure.
--
-- While 'WorkerAddr' is preserved, the passed 'WorkerLauncher'
-- launches workers on the node at 'WorkerAddr'. The launcher is
-- derived from 'workerLauncherWithRunCmd', where command runner is
-- either local shell (if 'WorkerAddr' is 'LocalHost') or a
-- 'RemoteFunction' that runs the local shell on 'WorkerAddr' via
-- 'withRemoteRunProcess' and related functions (if 'WorkerAddr' is
-- 'RemoteAddr').
--
-- Note that the process of launching a worker on the remote node will
-- actually spawn an \"utility\" worker there that will launch all new
-- workers in the continuation.  This utility worker will have its log
-- in the log dir, identified by some random 'ServiceId' and put
-- messages like \"Running command ...\".
--
-- The reason that utility workers are used on each Job node is to
-- minimize the number of calls to the command transport (@ssh@ or
-- @srun@). The naive way to launch workers in the 'Job' monad would
-- be to determine what node they should be run on, and run the
-- hyperion worker command via the command transport. Unfortunately,
-- many clusters have flakey configurations that start throwing errors
-- if e.g. @ssh@ is called too many times in quick succession. @ssh@
-- also has to perform authentication. Experience shows that @srun@ is
-- also not a good solution to this problem, since @srun@ talks to
-- @SLURM@ to manage resources and this can take a long time,
-- affecting performance. Instead, we use the command transport
-- exactly once to each node in the Job (besides the head node), and
-- start utility workers there. These workers can then communicate
-- with the head node via the usual machinery of @hyperion@ ---
-- effectively, we keep a connection open to each node so that we no
-- longer have to use the command transport.
withNodeLauncher
  :: NodeLauncherConfig
  -> WorkerAddr
  -> (Maybe (WorkerAddr, WorkerLauncher JobId) -> Process a)
  -> Process a
withNodeLauncher NodeLauncherConfig{..} addr' go = case addr' of
  WCP.RemoteAddr addr -> do
    remoteLauncher <- workerLauncherWithRunCmd nodeLogDir (liftIO . WCP.remoteRunCmd addr nodeCommandTransport)
    eitherResult <- try @Process @SSHError $ do
      withRemoteRunProcess remoteLauncher $ \remoteRunNode ->
        let
          runCmdOnNode cmd = do
            scp <- mkSerializableClosureProcess closureDict $ pure $
              static (liftIO . runCmdLocalLog) `cAp` cPure cmd
            remoteRunNode scp
        in
          workerLauncherWithRunCmd nodeLogDir runCmdOnNode >>= \launcher ->
          go (Just (addr', launcher))
    case eitherResult of
      Right result -> return result
      Left err -> do
        Log.warn "Couldn't start launcher" err
        go Nothing
  WCP.LocalHost _ ->
    workerLauncherWithRunCmd nodeLogDir (liftIO . runCmdLocalAsync) >>= \launcher ->
    go (Just (addr', launcher))


-- | Takes a `NodeLauncherConfig` and a list of addresses. Tries to
-- start \"worker-launcher\" workers on these addresses (see
-- 'withNodeLauncher').  Discards addresses on which the this
-- fails. From remaining addresses builds a worker CPU pool. The
-- continuation is then passed a function that launches workers in
-- this pool. The 'WorkerLaunchers' that continuation gets have
-- 'connectionTimeout' to 'Nothing'.
withPoolLauncher
  :: NodeLauncherConfig
  -> [WorkerAddr]
  -> ((NumCPUs -> WorkerLauncher JobId) -> Process a)
  -> Process a
withPoolLauncher cfg addrs' go = evalContT $ do
  mLaunchers <- mapM (ContT . withNodeLauncher cfg) addrs'
  let launcherMap = Map.fromList (catMaybes mLaunchers)
      addrs = Map.keys launcherMap
  workerCpuPool <- liftIO (WCP.newJobPool addrs)
  Log.info "Started worker launchers at" addrs
  lift $ go $ \nCpus -> WorkerLauncher
    { withLaunchedWorker = \nodeId serviceId goJobId ->
        WCP.withWorkerAddr workerCpuPool nCpus $ \addr ->
        withLaunchedWorker (launcherMap Map.! addr) nodeId serviceId goJobId
    , connectionTimeout = Nothing
    , onRemoteError     = \e _ -> throwM e
    }

remoteEvalJobM
  :: (Static (Binary b), Typeable b)
  => Cluster (Closure (Job b))
  -> Cluster b
remoteEvalJobM mc = do
  programInfo  <- asks clusterProgramInfo
  remoteEvalM $ do
    c <- mc
    pure $ static runJobSlurm `cAp` cPure programInfo `cAp` c

remoteEvalJob
  :: (Static (Binary b), Typeable b)
  => Closure (Job b)
  -> Cluster b
remoteEvalJob = remoteEvalJobM . pure
