{-# OPTIONS_GHC -fno-warn-orphans #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE RankNTypes      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RecordWildCards       #-}
{-# LANGUAGE TypeFamilies          #-}

module Hyperion.HasWorkers where

import           Control.Distributed.Process (Process)
import           Control.Monad.Base          (MonadBase (..))
import           Control.Monad.Reader        (ReaderT, asks)
import           Control.Monad.Trans.Control (MonadBaseControl (..), StM,
                                              control)
import           Data.Binary                 (Binary)
import           Data.Typeable               (Typeable)
import           GHC.StaticPtr               (StaticPtr)
import           Hyperion.Remote             (RemoteFunction,
                                              SerializableClosureProcess,
                                              WorkerLauncher, bindRemoteStatic,
                                              withRemoteRunProcess, RemoteProcessRunner)
import           Hyperion.Slurm              (JobId)

-- | A class for monads that can run things in the 'Process' monad,
-- and have access to a 'WorkerLauncher'. An instance of 'HasWorkers'
-- can use 'remoteBind' and 'remoteEval' to run computations in worker
-- processes at remote locations.
class MonadBaseControl Process m => HasWorkers m where
  getWorkerLauncher :: m (WorkerLauncher JobId)

-- | Trivial orphan instance of 'MonadBase' for 'Process'.
instance MonadBase Process Process where
  liftBase = id

-- | Trivial orphan instance of 'MonadBaseControl' for 'Process'
instance MonadBaseControl Process Process where
  type StM Process a = a
  liftBaseWith f = f id
  restoreM = return

-- | A class indicating that type 'env' contains a 'WorkerLauncher'.
class HasWorkerLauncher env where
  toWorkerLauncher :: env -> WorkerLauncher JobId

-- | This is our main instance for 'HasWorkers'. The 'Cluster' and
-- 'Job' monads are both cases of 'ReaderT env Process' with different
-- 'env's.
instance HasWorkerLauncher env => HasWorkers (ReaderT env Process) where
  getWorkerLauncher = asks toWorkerLauncher

-- | Uses the WorkerLauncher to get a RemoteProcessRunner and pass it
-- to the given continuation.
--
-- We use the machinery of 'MonadBaseControl' because
-- 'withRemoteRunProcess' expects something that runs in the 'Process'
-- monad, not in 'm'. Our main use case is when 'm ~ ReaderT env
-- Process', where 'env' is an instance of 'HasWorkerLauncher'. In
-- that case, we would like to capture the 'env' at the beginning, and
-- then use 'flip runReaderT env' to get from 'm' to 'Process' and
-- 'lift' to get from 'Process' back to 'm'. This is what the
-- 'MonadBaseControl' instance for ReaderT does.
--
withRemoteRun :: HasWorkers m => (RemoteProcessRunner -> m a) -> m a
withRemoteRun go = do
  workerLauncher <- getWorkerLauncher
  control $ \runInProcess ->
    withRemoteRunProcess workerLauncher $ \remoteRunProcess ->
    runInProcess (go remoteRunProcess)

-- | Evaluate 'ma' to get an argument, and pass that argument to the
-- given 'RemoteFunction', evaluating the result at a remote
-- location. The result is automatically serialized and sent back over
-- the wire. If you squint and replace 'StaticPtr (RemoteFunction a
-- b)' with 'a -> m b', then the type becomes 'm a -> (a -> m b) -> m
-- b', which is the type of bind ('>>='); hence the name 'remoteBind'.
remoteBind
  :: ( Binary a, Typeable a, Binary b, Typeable b, HasWorkers m
     , StM m (SerializableClosureProcess (Either String b)) ~ SerializableClosureProcess (Either String b)
     , StM m a ~ a
     )
  => m a
  -> StaticPtr (RemoteFunction a b)
  -> m b
remoteBind ma kRemotePtr = do
  serializableClosureProcess <- control $ \runInProcess ->
    runInProcess ma `bindRemoteStatic` kRemotePtr
  withRemoteRun $ \remoteRun -> liftBase $ remoteRun serializableClosureProcess

-- | Evaluate a 'RemoteFunction' on the given argument at a remote
-- location. The result is automatically serialized and sent back over
-- the wire. If you squint and replace 'StaticPtr (RemoteFunction a
-- b)' with 'a -> m b', then the type becomes '(a -> m b) -> a -> m
-- b', which is just function application.
remoteEval
  :: ( Binary a, Typeable a, Binary b, Typeable b, HasWorkers m
     , StM m (SerializableClosureProcess (Either String b)) ~ SerializableClosureProcess (Either String b)
     , StM m a ~ a
     )
  => StaticPtr (RemoteFunction a b)
  -> a
  -> m b
remoteEval kRemotePtr a = return a `remoteBind` kRemotePtr
