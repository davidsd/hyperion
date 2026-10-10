{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Distributed.Process.Internal.Types (LocalProcessId (..),
                                                   NodeId (..),
                                                   ProcessId (..),
                                                   SendPort (..),
                                                   SendPortId (..))
import Hyperion.Command                           (Worker (..), workerArgs)
import Hyperion.Main                              (HyperionOpts (..),
                                                   hyperionOpts)
import Hyperion.OsPath                            (OsPath)
import Hyperion.OsString                          (toString)
import Hyperion.ServiceId                         (ServiceId (..))
import Hyperion.Worker                            (Service (..))
import Hyperion.WorkerCommand                     (WorkerLaunch (..),
                                                   defaultWorkerCommand,
                                                   wrapWorkerCommand)
import Network.Transport                          (EndPointAddress (..))
import Options.Applicative                        (ParserResult (..),
                                                   defaultPrefs,
                                                   execParserPure, info)
import Test.Tasty                                 (defaultMain, testGroup)
import Test.Tasty.HUnit                           (assertFailure, testCase,
                                                   (@?=))

-- | A worker as a master would describe it: the given service id with a
-- port of the master for worker information, logging to the given file.
exampleWorker :: ServiceId -> OsPath -> Worker
exampleWorker serviceId logFile = Worker
  { workerLogFile = logFile
  , workerService = MkService
      { serviceId      = serviceId
      , workerInfoPort = SendPort SendPortId
          { sendPortProcessId = ProcessId
              { processNodeId  = NodeId (EndPointAddress "exp-3-54.expanse.sdsc.edu:45201:0")
              , processLocalId = LocalProcessId { lpidUnique = 1817, lpidCounter = 225 }
              }
          , sendPortLocalId = 1
          }
      }
  }

-- | Parses the given arguments as hyperion's command line does.
parseWorker :: [String] -> IO Worker
parseWorker args =
  case execParserPure defaultPrefs (info (hyperionOpts (pure ())) mempty) args of
    Success (HyperionWorker worker) -> pure worker
    Success (HyperionMaster ())     -> assertFailure "parsed as a master"
    Failure failure                 -> assertFailure ("parse failed: " <> show failure)
    CompletionInvoked _             -> assertFailure "completion invoked"

main :: IO ()
main = defaultMain $ testGroup "hyperion"
  [ testGroup "workerArgs parse back into the same worker"
    [ testCase "log file in a job's log directory" $ do
        let worker = exampleWorker (ServiceId "gd")
              "/expanse/lustre/scratch/dsd/temp_project/logs/2026-10/GjiQl/0/exp-8-21.53.log"
        parsed <- parseWorker (map toString (workerArgs worker))
        parsed @?= worker
    , testCase "log file path with spaces" $ do
        let worker = exampleWorker (ServiceId "AAAAAAAAAAJlbQ") "/tmp/a log dir/worker 1.log"
        parsed <- parseWorker (map toString (workerArgs worker))
        parsed @?= worker
    ]
  , testGroup "worker commands"
    [ testCase "defaultWorkerCommand runs the executable itself" $
        defaultWorkerCommand launch @?= ("/bin/bfss-exe", ["worker", "--logFile", "w.log"])
    , testCase "wrapWorkerCommand puts a program in front" $
        wrapWorkerCommand "/usr/bin/numactl" ["--interleave=all"] defaultWorkerCommand launch
          @?= ("/usr/bin/numactl", ["--interleave=all", "/bin/bfss-exe", "worker", "--logFile", "w.log"])
    ]
  ]
  where
    launch = WorkerLaunch
      { launchExecutable = "/bin/bfss-exe"
      , launchArguments  = ["worker", "--logFile", "w.log"]
      }
