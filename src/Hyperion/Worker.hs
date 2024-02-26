{-# LANGUAGE CPP                #-}
{-# LANGUAGE DeriveAnyClass     #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase         #-}
{-# LANGUAGE OverloadedStrings  #-}
{-# LANGUAGE RecordWildCards    #-}
{-# LANGUAGE StaticPointers     #-}

module Hyperion.Worker where

import Control.Distributed.Process         hiding (bracket, catch, try)
import Control.Distributed.Process.Node    qualified as Node
import Control.Distributed.Static          (registerStatic, staticLabel)
import Control.Monad.Trans.Maybe           (MaybeT (..))
import Data.Foldable                       (asum)
import Data.Rank1Dynamic                   (toDynamic)
import Hyperion.Config                     (HyperionStaticConfig)
import Hyperion.Log                        qualified as Log
import Hyperion.Remote                     (ServiceId (..), WorkerMessage (..))

masterNodeIdLabel :: String
masterNodeIdLabel = "masterNodeIdLabel"

masterNodeIdStatic :: Static (Maybe NodeId)
masterNodeIdStatic = staticLabel masterNodeIdLabel

getMasterNodeId :: Process (Maybe NodeId)
getMasterNodeId = unStatic masterNodeIdStatic

registerMasterNodeId :: Maybe NodeId -> RemoteTable -> RemoteTable
registerMasterNodeId nid = registerStatic masterNodeIdLabel (toDynamic nid)

workerStaticConfigLabel :: String
workerStaticConfigLabel  = "workerStaticConfig"

workerStaticConfigStatic :: Static HyperionStaticConfig
workerStaticConfigStatic = staticLabel workerStaticConfigLabel

getWorkerStaticConfig :: Process HyperionStaticConfig
getWorkerStaticConfig = unStatic workerStaticConfigStatic

registerWorkerStaticConfig :: HyperionStaticConfig -> RemoteTable -> RemoteTable
registerWorkerStaticConfig staticConfig = registerStatic workerStaticConfigLabel (toDynamic staticConfig)

initWorkerRemoteTable :: HyperionStaticConfig -> Maybe NodeId -> RemoteTable
initWorkerRemoteTable staticConfig nid = registerWorkerStaticConfig staticConfig . registerMasterNodeId nid $ Node.initRemoteTable

-- | The main worker process.
--
-- Repeatedly (at most 5 times) send our own 'ProcessId' and the send end of a typed channel
-- ('SendPort' 'WorkerMessage') to a master node until it replies
-- 'Connected' (timeout 10 seconds for each attempt).
-- Then 'expect' a 'ShutDown' signal.
--
-- While waiting, other processes will be run in a different thread,
-- invoked by master through our 'NodeId' (which it extracts from 'ProcessId')
worker
  :: NodeId     -- ^ 'NodeId' of the master node
  -> ServiceId  -- ^ 'ServiceId' of master 'Process' (should be 'register'ed)
  -> Process ()
worker masterNode serviceId@(ServiceId masterService) = do
  self <- getSelfPid
  (sendPort, receivePort) <- newChan

  let connectToMaster = MaybeT $ do
        Log.info "Connecting to master" masterNode
        nsendRemote masterNode masterService (self, serviceId, sendPort)
        receiveChanTimeout (10*1000*1000) receivePort

  runMaybeT (asum (replicate 5 connectToMaster)) >>= \case
    Just Connected -> do
      Log.text "Successfully connected to master."
      expect >>= \case
        Connected -> Log.throwError "Unexpected 'Connected' received."
        ShutDown  -> Log.text "Shutting down."
    _ -> Log.text "Couldn't connect to master" >> die ()
