{-# LANGUAGE ApplicativeDo     #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE StaticPointers    #-}

module Main where

import            Hyperion
import qualified  Hyperion.Slurm        as Slurm
import qualified  Hyperion.Log          as Log
import            Hyperion.Util         (uncurry4, curry4, uncurry3, curry3)
import            Hyperion.Database.KeyValMap
import            Options.Applicative
import            Control.Monad.IO.Class
import            Control.Monad.Reader
import            Data.Monoid
import            System.FilePath.Posix  ((</>))
import            GHC.StaticPtr

type Bracket = (Double, Double)

binarySearchFunction :: (Double -> Double) -> Double -> Bracket -> Double -> Bracket
binarySearchFunction f x bracket eps = go bracket
  where
    go (down, up) | up - down < eps = (down, up)
                  | f mid >= x      = go (down, mid)
                  | otherwise       = go (mid, up)
      where
        mid = (down + up) / 2

rootBinarySearch :: MonadIO m => Int -> Double -> Bracket -> Double -> m Bracket
rootBinarySearch n x brckt eps = do
  Log.info "Running binary search at " (x, brckt, eps)
  let result = binarySearchFunction (^n) x brckt eps
  Log.info "Computed bracket ------- " result
  return result

rootBinarySearchStatic :: StaticPtr (RemoteFunction (Int, Double, Bracket, Double) Bracket)
rootBinarySearchStatic = static (remoteFn $ uncurry4 rootBinarySearch)

runRemoteRootBinarySearch :: Int -> Double -> Bracket -> Double -> Job Bracket
runRemoteRootBinarySearch = curry4 $ remoteEval rootBinarySearchStatic

binarySearchJob :: Int -> [Double] -> Double -> Job [Bracket]
binarySearchJob n points eps = do
  Log.info "Computing inverse to x^n with n" n
  Log.info "Running binary searches at     " points
  Log.info "Stopping searches at precision " eps
  mapConcurrently (runSearchMemoized n) points
  where
    runSearch :: Int -> Double -> Job Bracket
    runSearch m x = runRemoteRootBinarySearch m x (0, max 1 x) eps
    runSearchMemoized = curry $ memoizeWithMap kvmap $ uncurry runSearch
    kvmap = KeyValMap "binary_root_search"

binarySearchJobStatic :: StaticPtr (RemoteFunction ((Int, [Double], Double), ProgramInfo) [Bracket])
binarySearchJobStatic = static (remoteFnJob $ uncurry3 binarySearchJob)

runRemoteBinarySearchJob :: Int -> [Double] -> Double -> Cluster [Bracket]
runRemoteBinarySearchJob = curry3 $ remoteEvalJob binarySearchJobStatic

clusterComputation :: ProgramOptions -> Cluster ()
clusterComputation ProgramOptions{..} = do
  Log.text "Running an example computation"
  let
    point i = fromIntegral i * (xMax - xMin)/(fromIntegral nPoints - 1) + xMin
    points = map point [0 .. nPoints-1]
    runRootNJob n = local (setJobType MPIJob{ mpiNodes = 2, mpiNTasksPerNode = 2 }) $
      runRemoteBinarySearchJob n points eps
  mapConcurrently_ runRootNJob [2,3,4]

data ProgramOptions = ProgramOptions
  { xMin          :: Double
  , xMax          :: Double
  , eps           :: Double
  , nPoints       :: Int
  , baseDirectory :: FilePath
  } deriving (Show)

programOpts :: Parser ProgramOptions
programOpts = do
  baseDirectory <-
    strOption (long "baseDir" <> metavar "PATH" 
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
