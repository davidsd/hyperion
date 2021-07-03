{-# OPTIONS_GHC -fno-warn-orphans  #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE RecordWildCards       #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE StaticPointers        #-}
{-# LANGUAGE TypeApplications      #-}
{-# LANGUAGE TypeFamilies          #-}

module Hyperion.HasWorkers where

import           Control.Distributed.Process (Closure, Process)
import           Control.Monad.Base          (MonadBase (..))
import           Control.Monad.IO.Class      (MonadIO)
import           Control.Monad.Reader        (ReaderT (..), asks, runReaderT)
import           Data.Binary                 (Binary)
import           Data.Constraint             (Dict (..))
import           Data.Typeable               (Typeable)
import           Hyperion.Remote             (RemoteProcessRunner,
                                              WorkerLauncher,
                                              mkSerializableClosureProcess,
                                              withRemoteRunProcess)
import           Hyperion.Slurm              (JobId)
import           Hyperion.Static             (Serializable, Static (..))

-- | A class for monads that can run things in the 'Process' monad,
-- and have access to a 'WorkerLauncher'. An instance of 'HasWorkers'
-- can use 'remoteBind' and 'remoteEval' to run computations in worker
-- processes at remote locations.
class (MonadBase Process m, MonadUnliftProcess m, MonadIO m) => HasWorkers m where
  getWorkerLauncher :: m (WorkerLauncher JobId)

-- | Trivial orphan instance of 'MonadBase' for 'Process'.
instance MonadBase Process Process where
  liftBase = id

-- | A class for Monads that can run continuations in the Process
-- monad, modeled after MonadUnliftIO
-- (https://hackage.haskell.org/package/unliftio-core-0.2.0.1/docs/Control-Monad-IO-Unlift.html).
class MonadUnliftProcess m where
  withRunInProcess :: ((forall a. m a -> Process a) -> Process b) -> m b

instance MonadUnliftProcess Process where
  withRunInProcess go = go id

instance MonadUnliftProcess m => MonadUnliftProcess (ReaderT r m) where
  withRunInProcess inner =
    ReaderT $ \r ->
    withRunInProcess $ \run ->
    inner (run . flip runReaderT r)

-- | A class indicating that type 'env' contains a 'WorkerLauncher'.
class HasWorkerLauncher env where
  toWorkerLauncher :: env -> WorkerLauncher JobId

-- | This is our main instance for 'HasWorkers'. The 'Cluster' and
-- 'Job' monads are both cases of 'ReaderT env Process' with different
-- 'env's.
instance HasWorkerLauncher env => HasWorkers (ReaderT env Process) where
  getWorkerLauncher = asks toWorkerLauncher

-- | Uses the 'WorkerLauncher' to get a 'RemoteProcessRunner' and pass it
-- to the given continuation.
--
-- This function is essentially a composition of 'getWorkerLauncher' with
-- 'withRemoteRunProcess', lifted from 'Process' to 'm' using 'MonadUnliftProcess'.
--
-- We use the machinery of 'MonadUnliftProcess' because
-- 'withRemoteRunProcess' expects something that runs in the 'Process'
-- monad, not in 'm'. Our main use case is when 'm ~ ReaderT env
-- Process', where 'env' is an instance of 'HasWorkerLauncher'.
--
withRemoteRun :: HasWorkers m => (RemoteProcessRunner -> m a) -> m a
withRemoteRun go = do
  workerLauncher <- getWorkerLauncher
  withRunInProcess $ \runInProcess ->
    withRemoteRunProcess workerLauncher $ \remoteRunProcess ->
    runInProcess (go remoteRunProcess)

-- | Compute a closure at a remote location. The user supplies an 'm
-- (Closure (...))' which is only evaluated when a remote worker
-- becomes available (for example after the worker makes it out of the
-- Slurm queue).
--
-- This function is more general that 'remoteBind' and 'remoteEval'
-- because the user can supply an arbitrary 'Closure'. The price is
-- that 'Closure (Dict (Serializable ...))'s need to be supplied
-- somehow -- either via the 'Static' typeclass or explicitly.
remoteClosureWithDictM
  :: (HasWorkers m, Serializable b)
  => Closure (Dict (Serializable b))
  -> m (Closure (Process b))
  -> m b
remoteClosureWithDictM bDict mb = do
  scp <- withRunInProcess $ \runInProcess -> mkSerializableClosureProcess bDict (runInProcess mb)
  withRemoteRun (\remoteRun -> liftBase (remoteRun scp))

-- | A version of remoteClosure' that gets the 'Closure (Dict
-- (Serializable b))' from a 'Static'
remoteClosureM
  :: (HasWorkers m, Static (Binary b), Typeable b)
  => m (Closure (Process b))
  -> m b
remoteClosureM = remoteClosureWithDictM closureDict

-- | A version of remoteClosure' that gets the 'Closure (Dict
-- (Serializable b))' from a 'Static'
remoteClosure
  :: (HasWorkers m, Static (Binary b), Typeable b)
  => Closure (Process b)
  -> m b
remoteClosure = remoteClosureM . pure
