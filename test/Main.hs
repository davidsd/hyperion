{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Distributed.Process.Internal.Types (LocalProcessId (..),
                                                   NodeId (..), ProcessId (..),
                                                   SendPort (..),
                                                   SendPortId (..))
import Control.Exception                          (bracket_, try)
import Hyperion.Command                           (Worker (..),
                                                   hyperionWorkerCommand)
import Hyperion.Main                              (HyperionOpts (..),
                                                   hyperionOpts)
import Hyperion.OsPath                            (OsPath)
import Hyperion.OsString                          (OsString, fromString,
                                                   toString)
import Hyperion.ServiceId                         (ServiceId (..))
import Hyperion.Slurm.JobId                       (JobId (..))
import Hyperion.Slurm.Sbatch                      (SbatchError (..),
                                                   SbatchOptions (..),
                                                   defaultSbatchOptions,
                                                   sbatchCommand)
import Hyperion.Util                              (shellEsc)
import Hyperion.Worker                            (Service (..))
import Hyperion.WorkerCommand                     (defaultWorkerCommand,
                                                   wrapWorkerCommand)
import Network.Transport                          (EndPointAddress (..))
import Options.Applicative                        (ParserResult (..),
                                                   defaultPrefs, execParserPure,
                                                   info)
import System.Directory                           (getPermissions,
                                                   setOwnerExecutable,
                                                   setPermissions)
import System.Environment                         (getEnv, setEnv)
import System.FilePath                            ((</>))
import System.IO                                  (readFile')
import System.IO.Temp                             (withSystemTempDirectory)
import System.Process                             (readProcess)
import Test.Tasty                                 (DependencyType (..),
                                                   defaultMain,
                                                   dependentTestGroup,
                                                   testGroup)
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

-- | The command that runs the given worker.
commandOf :: Worker -> (OsString, [OsString])
commandOf worker =
  hyperionWorkerCommand "/bin/bfss-exe" (workerService worker) (workerLogFile worker)

-- | Parses the given arguments as hyperion's command line does.
parseWorker :: [String] -> IO Worker
parseWorker args =
  case execParserPure defaultPrefs (info (hyperionOpts (pure ())) mempty) args of
    Success (HyperionWorker worker) -> pure worker
    Success (HyperionMaster ())     -> assertFailure "parsed as a master"
    Failure failure                 -> assertFailure ("parse failed: " <> show failure)
    CompletionInvoked _             -> assertFailure "completion invoked"

-- | The arguments that the given program gets when @sh@ runs it with the
-- given arguments escaped by 'shellEsc'. The arguments must not contain
-- newlines; the program must be one written by 'writePrintArgs'.
argsAfterShell :: FilePath -> [OsString] -> IO [String]
argsAfterShell program args =
  lines <$> readProcess "sh" ["-c", toString (shellEsc (fromString program) args)] ""

-- | Arguments that a shell would change unless they are escaped. No newlines.
trickyArgs :: [OsString]
trickyArgs = ["a b", "it's", "$HOME", "`id`", "a\"b\\c", "%d", "", "--interleave=all"]

-- | Runs the action on a new directory whose path has a space.
withTestDir :: (FilePath -> IO a) -> IO a
withTestDir = withSystemTempDirectory "hyperion test"

-- | Writes an executable @sh@ script with the given lines.
writeScript :: FilePath -> [String] -> IO ()
writeScript path body = do
  writeFile path (unlines ("#!/bin/sh" : body))
  setPermissions path . setOwnerExecutable True =<< getPermissions path

-- | Writes, to the given directory, a program that prints its arguments, one
-- per line, and returns its path. The path has a space.
writePrintArgs :: FilePath -> IO FilePath
writePrintArgs dir = do
  let program = dir </> "print args"
  writeScript program ["printf '%s\\n' \"$@\""]
  pure program

-- | Runs the action with @PATH@ set to the given value.
withPath :: String -> IO a -> IO a
withPath path go = do
  oldPath <- getEnv "PATH"
  bracket_ (setEnv "PATH" path) (setEnv "PATH" oldPath) go

-- | Runs the action with a fake @sbatch@ first on @PATH@. The fake writes its
-- arguments, one per line, to @args@ and its stdin to @script@ in the given
-- directory.
withFakeSbatch :: FilePath -> IO a -> IO a
withFakeSbatch dir go = do
  writeScript (dir </> "sbatch")
    [ "printf '%s\\n' \"$@\" > \"$(dirname \"$0\")/args\""
    , "cat > \"$(dirname \"$0\")/script\""
    , "echo 'Submitted batch job 42'"
    ]
  path <- getEnv "PATH"
  withPath (dir <> ":" <> path) go

-- Sequential: the sbatchCommand tests change PATH, which all tests share.
main :: IO ()
main = defaultMain $ dependentTestGroup "hyperion" AllFinish
  [ testGroup "hyperionWorkerCommand parses back into the same worker"
    [ testCase "log file in a job's log directory" $ do
        let worker = exampleWorker (ServiceId "gd")
              "/expanse/lustre/scratch/dsd/temp_project/logs/2026-10/GjiQl/0/exp-8-21.53.log"
        parsed <- parseWorker (map toString (snd (commandOf worker)))
        parsed @?= worker
    , testCase "through sh, log file path with spaces" $
        withTestDir $ \dir -> do
          printArgs <- writePrintArgs dir
          let worker = exampleWorker (ServiceId "AAAAAAAAAAJlbQ") "/tmp/a log dir/worker 1.log"
          parsed <- parseWorker =<< argsAfterShell printArgs (snd (commandOf worker))
          parsed @?= worker
    ]
  , testCase "shellEsc keeps the command and every argument as is" $
      withTestDir $ \dir -> do
        printArgs <- writePrintArgs dir
        printed <- argsAfterShell printArgs trickyArgs
        printed @?= map toString trickyArgs
  , dependentTestGroup "sbatchCommand" AllFinish
    [ testCase "passes options, preamble and arguments as they are" $
        withTestDir $ \dir -> withFakeSbatch dir $ do
          printArgs <- writePrintArgs dir
          let jobDir = dir </> "job dir"
              opts = defaultSbatchOptions
                { jobName        = Just "it's a job"
                , chdir          = Just (fromString jobDir)
                , scriptPreamble = Just "echo pre; echo amble"
                }
          jobId <- sbatchCommand opts (fromString printArgs) trickyArgs
          jobId @?= JobId "42"
          sbatchArgs <- lines <$> readFile' (dir </> "args")
          sbatchArgs @?=
            [ "--job-name", "it's a job", "-D", jobDir, "--nodes", "1"
            , "--ntasks-per-node", "1", "--time", "24:00:00", "--no-requeue" ]
          printed <- readProcess "sh" [dir </> "script"] ""
          lines printed @?= ["pre", "amble"] ++ map toString trickyArgs
    , testCase "reports an sbatch that cannot be started as SbatchError" $
        withTestDir $ \dir -> withPath dir $ do
          outcome <- try @SbatchError (sbatchCommand defaultSbatchOptions "true" [])
          case outcome of
            Left (SbatchError (Left _) _) -> pure ()
            _ -> assertFailure ("expected an SbatchError with a Left result, got " <> show outcome)
    ]
  , testGroup "worker commands"
    [ testCase "defaultWorkerCommand runs the executable itself" $
        defaultWorkerCommand command @?= command
    , testCase "wrapWorkerCommand puts a program in front" $
        wrapWorkerCommand "/usr/bin/numactl" ["--interleave=all"] command
          @?= ("/usr/bin/numactl", ["--interleave=all", "/bin/bfss-exe", "worker", "--logFile", "w.log"])
    ]
  ]
  where
    command = ("/bin/bfss-exe", ["worker", "--logFile", "w.log"])
