{-# LANGUAGE ApplicativeDo     #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE StaticPointers    #-}

module Main where

import           Control.Monad.Reader        (local)
import           Data.Monoid                 ((<>))
import           GHC.StaticPtr               (StaticPtr)
import           Hyperion
import           Hyperion.Database.KeyValMap (KeyValMap(..), memoizeWithMap)
import qualified Hyperion.Log                as Log
import qualified Hyperion.Slurm              as Slurm
import           Hyperion.Util               (curry3, curry4, uncurry3, uncurry4)
import           Options.Applicative         (Parser, auto, help, long, metavar, option, str)
import           System.FilePath.Posix       ((</>))

-- | An interval of 'Double's giving lower and upper bounds for some
-- quantity
type Bracket = (Double, Double)

-- | Given a function @f :: Double -> Double@ and value @x@, search
-- for a 'Bracket' around @f^{-1}(x)@ via binary search until the
-- 'Bracket' has width @eps@. The function is assumed to be
-- monotonically increasing and the initial 'Bracket' is assumed to
-- have the form @(down, up)@, where @up > down@.
binarySearchInverse
  :: (Double -> Double) -- ^ function @f@ to invert
  -> Double             -- ^ argument @x@ to inverse function
  -> Bracket            -- ^ an initial Bracket for @f^{-1}(x)@
  -> Double             -- ^ target accuracy @eps@ for binary search
  -> Bracket            -- ^ a Bracket around the value @f^{-1}(x)@ with accuracy @eps@
binarySearchInverse f x bracket eps = go bracket
  where
    go (down, up) | up - down < eps = (down, up)
                  | f mid >= x      = go (down, mid)
                  | otherwise       = go (mid, up)
      where
        mid = (down + up) / 2

-- * IO computation

-- | Run a binary search for the inverse of @f(x)=x^n@, printing and
-- returning the result. This IO computation will be run on a node
-- available to a SLURM job.
rootBinarySearch :: Int -> Double -> Bracket -> Double -> IO Bracket
rootBinarySearch n x brckt eps = do
  Log.info "Running binary search at " (x, brckt, eps)
  let result = binarySearchInverse (^n) x brckt eps
  Log.info "Computed bracket ------- " result
  return result

-- * Preparing for 'remoteEval'
-- $
-- We would like a job to be able to run 'rootBinarySearch' remotely,
-- so that it can make use of all the nodes available to a job. To do
-- so, we must create a @StaticPtr (RemoteFunction a b)@ that can be
-- used with 'remoteEval'.

-- | Create the 'StaticPtr' of a 'RemoteFunction', needed by
-- 'remoteEval'. A 'RemoteFunction' takes one argument and returns one
-- result. Thus, we use 'uncurry4' to turn 'rootBinarySearch' into a
-- function that takes one tuple as an argument.
rootBinarySearchStatic :: StaticPtr (RemoteFunction (Int, Double, Bracket, Double) Bracket)
rootBinarySearchStatic = static (remoteFnIO $ uncurry4 rootBinarySearch)

-- | Given a @StaticPtr (RemoteFunction a b)@, 'remoteEval' evaluates
-- the function on an argument at a remote location. In the 'Job'
-- monad, 'remoteEval' runs the given function on the best available
-- node in the SLURM job. For example, if the job involves 2 nodes
-- with 2 CPUs each, 'remoteEval' checks how many cores are free on
-- each of the 2 nodes and calls 'remoteEval' on the node with the
-- largest number of free cores. In this case, the task requires 1
-- core. If no nodes have at least 1 free core, 'remoteEval' waits
-- until one becomes available. Tasks are run in
-- first-come-first-serve order.
runRemoteRootBinarySearch :: Int -> Double -> Bracket -> Double -> Job Bracket
runRemoteRootBinarySearch = curry4 $ remoteEval rootBinarySearchStatic

-- * Job computation
-- $
-- We now define the main computation for a SLURM job. This
-- computation will be started on one of the nodes of a SLURM job (the
-- "head node"). Using 'remoteEval', it can make use of all the
-- resources in the job in parallel (including its own node).

-- | Perform a binary search for the inverse of @f(x)=x^n@ on a
-- collection of @points@. The points are computed concurrently on all
-- cores available to the SLURM job. In this example, the SLURM job
-- has 2 nodes with 2 cores each. Thus, binary searches will be run
-- simultaneously on 4 points at a time. When one search finishes,
-- another is started immediately until all points are finished.
--
-- The results are recorded to the SQLIte database in a table called
-- @binary_root_search@ via the use of 'memoizeWithMap'. The database
-- is the preferred way of storing and retrieving results.
binarySearchJob :: Int -> [Double] -> Double -> Job [Bracket]
binarySearchJob n points eps = do
  Log.info "Computing inverse to x^n with n" n
  Log.info "Running binary searches at     " points
  Log.info "Stopping searches at precision " eps
  result <- mapConcurrently (runSearchMemoized n) points
  Log.info "Computed brackets" (zip points result)
  return result
  where
    runSearch :: Int -> Double -> Job Bracket
    runSearch m x = runRemoteRootBinarySearch m x (0, max 1 x) eps
    runSearchMemoized = curry $ memoizeWithMap kvmap $ uncurry runSearch
    kvmap = KeyValMap "binary_root_search"

-- * Preparing for remoteEval
-- $
-- We would like to be able to submit concurrent SLURM jobs, each
-- running 'binarySearchJob' on different inputs. To do so, we again
-- have to create a @StaticPtr (RemoteFunction a b)@ for use with
-- 'remoteEval'.

-- | Create a 'StaticPtr' of a 'RemoteFunction' so that
-- 'binarySearchJob' can be run remotely. Again, because a
-- 'RemoteFunction' takes a single argument, we use 'uncurry3' to
-- group arguments into a tuple. Because 'binarySearchJob' is in the
-- 'Job' monad instead of 'IO', we must use 'remoteFnJob' to create
-- the 'RemoteFunction'.
binarySearchJobStatic :: StaticPtr (RemoteFunction ((Int, [Double], Double), ProgramInfo) [Bracket])
binarySearchJobStatic = static (remoteFnJob $ uncurry3 binarySearchJob)

-- | In the 'Cluster' monad, 'remoteEvalJob' runs the given function
-- in a new SLURM job. A job with the needed resources is
-- automatically submitted via @sbatch@. The function
-- 'binarySearchJob' is run in the job and the reult is automatically
-- sent back over the wire.
runRemoteBinarySearchJob :: Int -> [Double] -> Double -> Cluster [Bracket]
runRemoteBinarySearchJob = curry3 $ remoteEvalJob binarySearchJobStatic

-- * Cluster computation
-- $
-- We now define the master computation, which can be run on a cluster
-- node, login node, or some other machine that can run sbatch. Using
-- 'remoteEval', it runs remote computations concurrently in different
-- SLURM jobs.

-- | Compute the inverses of the functions @x^2, x^3, x^4@ acting on
-- 'nPoints' points between 'xMin' and 'xMax'. The computations are
-- run concurrently in 3 differnt SLURM jobs.
clusterComputation :: ProgramOptions -> Cluster ()
clusterComputation ProgramOptions{..} =
  -- For each submitted job, require 2 nodes with 2 cores each
  local (setJobType MPIJob{ mpiNodes = 2, mpiNTasksPerNode = 2 }) $ do
  Log.text "Running an example computation"
  -- Concurrently run binarySearchJob in 3 different SLURM jobs
  forConcurrently_ [2,3,4] $ \n -> do
    roots <- runRemoteBinarySearchJob n points eps
    Log.info "Computed roots" (n, zip points roots)
  where
    point i = fromIntegral i * (xMax - xMin)/(fromIntegral nPoints - 1) + xMin
    points = map point [0 .. nPoints-1]

-- | A datatype for command line arguments
data ProgramOptions = ProgramOptions
  { xMin          :: Double   -- ^ Lower end of the interval
  , xMax          :: Double   -- ^ Upper end of the interval
  , eps           :: Double   -- ^ Desired precision
  , nPoints       :: Int      -- ^ Number of points to sample in the interval
  , baseDirectory :: FilePath -- ^ Base directory for log files, databases, etc.
  } deriving (Show)

-- | Parser for command line arguments
programOpts :: Parser ProgramOptions
programOpts = do
  baseDirectory <-
    option str (long "baseDir" <> metavar "PATH"
      <> help "The base directory for all the stuff (use an absolute path).")
  xMin <-
    option auto (long "xMin" <> metavar "NUM" <> help "Lower end of the interval")
  xMax <-
    option auto (long "xMax" <> metavar "NUM" <> help "Upper end of the interval")
  eps <-
    option auto (long "eps" <> metavar "NUM" <> help "Desired precision")
  nPoints <-
    option auto (long "nPoints" <> metavar "INT"
      <> help "Number of points to sample in the interval")
  pure ProgramOptions{..}

-- | Given parsed command line arguments, return a 'HyperionConfig'.
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
    hyperionCommand       = Nothing
    initialDatabase       = Nothing
    sshRunCommand         = Just ("ssh", ["-f", "-o", "StrictHostKeyChecking no"])
  in HyperionConfig{..}

main :: IO ()
main = hyperionMain programOpts mkHyperionConfig clusterComputation
