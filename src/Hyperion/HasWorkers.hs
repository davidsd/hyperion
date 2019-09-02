{-# OPTIONS_GHC -fno-warn-orphans #-}
{-# LANGUAGE FlexibleContexts      #-}
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
import           Hyperion.Remote
import           Hyperion.Slurm              (JobId (..))

class MonadBaseControl Process m => HasWorkers m where
  getWorkerLauncher :: m (WorkerLauncher JobId)

instance MonadBase Process Process where
  liftBase = id

instance MonadBaseControl Process Process where
  type StM Process a = a
  liftBaseWith f = f id
  restoreM = return

class HasWorkerLauncher env where
  toWorkerLauncher :: env -> WorkerLauncher JobId

instance HasWorkerLauncher env => HasWorkers (ReaderT env Process) where
  getWorkerLauncher = asks toWorkerLauncher

withRemoteRun
  :: (Binary a, Typeable a, HasWorkers m)
  => ((SerializableClosureProcess a -> Process a) -> m b)
  -> m b
withRemoteRun go = do
  workerLauncher <- getWorkerLauncher
  control $ \runInProcess ->
    withRemoteRunProcess workerLauncher $ \remoteRunProcess ->
    runInProcess (go remoteRunProcess)

remoteBind
  :: (Binary a, Typeable a, Binary b, Typeable b, HasWorkers m, StM m b ~ b, StM m a ~ a)
  => m a
  -> StaticPtr (RemoteFunction a b)
  -> m b
remoteBind ma kRemotePtr =
  withRemoteRun $ \remoteRun ->
    control $ \runInProcess ->
    remoteRun =<< runInProcess ma `bindRemoteStatic` kRemotePtr

remoteEval
  :: (Binary a, Typeable a, Binary b, Typeable b, HasWorkers m, StM m b ~ b, StM m a ~ a)
  => StaticPtr (RemoteFunction a b)
  -> a
  -> m b
remoteEval kRemotePtr a = return a `remoteBind` kRemotePtr
