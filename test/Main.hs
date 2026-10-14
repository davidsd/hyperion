{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Exception     (bracket_, try)
import Hyperion.OsString     (OsString, fromString, toString)
import Hyperion.Slurm.JobId  (JobId (..))
import Hyperion.Slurm.Sbatch (SbatchError (..), SbatchOptions (..),
                              defaultSbatchOptions, sbatchCommand)
import Hyperion.Util         (shellEsc)
import System.Directory      (getPermissions, setOwnerExecutable,
                              setPermissions)
import System.Environment    (getEnv, setEnv)
import System.FilePath       ((</>))
import System.IO             (readFile')
import System.IO.Temp        (withSystemTempDirectory)
import System.Process        (readProcess)
import Test.Tasty            (DependencyType (..), defaultMain,
                              dependentTestGroup)
import Test.Tasty.HUnit      (assertFailure, testCase, (@?=))

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
  [ testCase "shellEsc keeps the command and every argument as is" $
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
  ]
