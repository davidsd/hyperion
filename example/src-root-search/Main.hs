{-# LANGUAGE ApplicativeDo     #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE StaticPointers    #-}

-- | This module defines a simple routine 'rootBinarySearch' that
-- performs a binary search for the n-th root of a number and returns
-- the result. The function is run in parallel in multiple Slurm jobs,
-- and on multiple nodes/cores within each job. Results are stored in
-- a database and also sent back to the master process for printing.
--
-- The structure of this example computation is as follows
--
--        Master    <==== Cluster monad
--        |  |  |
--   -----   |   -------
--  |        |          |
-- Job 1    Job 2      Job 3    <==== Job monad
--  | |      | |        | |
--  | |      | |        |  --------------------------------
--  | |      | |         -----------------------           |
--  | |      |  ---------------------           |          |
--  | |       ------------           |          |          |
--  |  --------           |          |          |          |
--  |          |          |          |          |          |
--  Node 1a    Node 1b    Node 2a    Node 2b    Node 3a    Node 3b    <==== Process monad
--  (2 cores)  (2 cores)  (2 cores)  (2 cores)  (2 cores)  (2 cores)
--
-- The Master process runs in the Cluster monad, which can call
-- 'remoteEval' to automatically evaluate a function using a Slurm
-- job. Each Slurm job runs in the Job monad, which can call
-- 'remoteEval' to automatically evaluate a function on one of the
-- nodes available to the job. At the lowest level, computations run
-- in the Process monad from Control.Distributed.Process.
--
-- Each job computes the n-th root of a list of numbers. 3 jobs are
-- run concurrently, with n=2,3,4. Within each job, the numbers are
-- assigned to different cores on different nodes as they become
-- available.
--
module Main where

import           Control.Distributed.Process (Process)
import           Control.Monad.Reader        (local)
import           Hyperion
import           Hyperion.Database.KeyValMap (KeyValMap (..), memoizeWithMap)
import qualified Hyperion.Log                as Log
import qualified Hyperion.Slurm              as Slurm
import           Options.Applicative         (Parser, auto, help, long, metavar,
                                              option, str)
import           System.FilePath.Posix       ((</>))

-- | lower and upper bounds for some quantity
type Bracket = (Double, Double)

-- | Given a function f and value x, find a bracket of width eps
-- around f^{-1}(x) via binary search.
binarySearchInverse :: (Double -> Double) -> Double -> Bracket -> Double -> Bracket
binarySearchInverse f x bracket eps = go bracket
  where
    go (down, up) | up - down < eps = (down, up)
                  | f mid >= x      = go (down, mid)
                  | otherwise       = go (mid, up)
      where
        mid = (down + up) / 2

-- | Search for inverse of 'f(x)=x^n', and print the result.
rootBinarySearch :: Int -> Double -> Bracket -> Double -> Process Bracket
rootBinarySearch n x bracket eps = do
  Log.info "Running binary search at " (x, bracket, eps)
  let result = binarySearchInverse (^n) x bracket eps
  Log.info "Computed bracket ------- " result
  return result

-- | Run 'rootBinarySearch' remotely on a node available to the job
-- (location chosen automatically).
runRemoteRootBinarySearch :: Int -> Double -> Bracket -> Double -> Job Bracket
runRemoteRootBinarySearch n x bracket eps = remoteEval $
  static rootBinarySearch `ptrAp` cPure n `cAp` cPure x `cAp` cPure bracket `cAp` cPure eps

-- | The main computation for a Slurm job, which runs on the head node
-- of the job. It concurrently runs computations on different job
-- nodes via 'remoteEval'.
binarySearchJob :: Int -> [Double] -> Double -> Job [Bracket]
binarySearchJob n points eps = do
  Log.info "Computing inverse to x^n with n" n
  Log.info "Running binary searches at     " points
  Log.info "Stopping searches at precision " eps
  -- | Concurrently compute 'runSearchMemoized n p' for all p in
  -- points. New computations are automatically started as cores
  -- become available.
  result <- mapConcurrently (runSearchMemoized n) points
  Log.info "Computed brackets" (zip points result)
  return result
  where
    runSearch :: Int -> Double -> Job Bracket
    runSearch m x = runRemoteRootBinarySearch m x (0, max 1 x) eps
    -- | 'runSearchMemoized' automatically stores the result of all
    -- calls to 'runSearch' in the database.
    runSearchMemoized = curry $ memoizeWithMap kvmap $ uncurry runSearch
    kvmap = KeyValMap "binary_root_search"

-- | Compute 'binarySearchJob' remotely in a new Slurm job (submitted
-- automatically).
runRemoteBinarySearchJob :: Int -> [Double] -> Double -> Cluster [Bracket]
runRemoteBinarySearchJob n points eps = remoteEvalJob $
  static binarySearchJob `ptrAp` cPure n `cAp` cPure points `cAp` cPure eps

-- | The master computation, which can be run on a cluster node, login
-- node, or some other machine with access to sbatch. It concurrently
-- runs remote computations in different Slurm jobs via 'remoteEval'.
clusterComputation :: ProgramOptions -> Cluster ()
clusterComputation ProgramOptions{..} =
  -- | For each submitted job, require 2 nodes with 2 cores each
  local (setJobType (MPIJob 2 2)) $ do
  Log.text "Running an example computation"
  -- | Concurrently run runRemoteBinarySearchJob for n=2,3,4. This
  -- code will submit 3 different Slurm jobs.
  forConcurrently_ [2,3,4] $ \n -> do
    roots <- runRemoteBinarySearchJob n points eps
    Log.info "Computed roots" (n, zip points roots)
  where
    point i = fromIntegral i * (xMax - xMin)/(fromIntegral nPoints - 1) + xMin
    points = map point [0 .. nPoints-1]

-- | A datatype for command line arguments
data ProgramOptions = ProgramOptions
  { xMin          :: Double
  , xMax          :: Double
  , eps           :: Double
  , nPoints       :: Int
  , baseDirectory :: FilePath
  } deriving (Show)

-- | Parser for command line arguments
programOpts :: Parser ProgramOptions
programOpts = do
  baseDirectory <-
    option str (long "baseDir" <> metavar "PATH"
                <> help "The base directory for writing files (absolute path)")
  xMin    <- option auto (long "xMin" <> metavar "NUM"
                          <> help "Lower end of the interval")
  xMax    <- option auto (long "xMax" <> metavar "NUM"
                          <> help "Upper end of the interval")
  eps     <- option auto (long "eps"  <> metavar "NUM"
                          <> help "Desired precision")
  nPoints <- option auto (long "nPoints" <> metavar "INT"
                          <> help "Number of points to sample in the interval")
  pure ProgramOptions{..}

-- | Compute a 'HyperionConfig' from the comand line arguments.
mkHyperionConfig :: ProgramOptions -> HyperionConfig
mkHyperionConfig ProgramOptions{..} =
  let
    defaultSbatchOptions  = Slurm.defaultSbatchOptions {
      Slurm.output = Just $ baseDirectory </> "slurmOutput" </> "work-%j.out"
    }
    dataDir               = baseDirectory </> "dataDir"
    logDir                = baseDirectory </> "logDir"
    databaseDir           = baseDirectory </> "databaseDir"
    execDir               = baseDirectory </> "execDir"
    jobDir                = baseDirectory </> "jobDir"
    hyperionCommand       = Nothing
    initialDatabase       = Nothing
    emailAddr             = Nothing
    maxSlurmJobs          = Nothing
    remoteTool         = SSH $ Just ("ssh", ["-f", "-o", "StrictHostKeyChecking no"])
  in HyperionConfig{..}

main :: IO ()
main = hyperionMain programOpts mkHyperionConfig clusterComputation
