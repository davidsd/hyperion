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
import            Control.Distributed.Process
import            Data.Monoid
import            Data.Maybe             (fromMaybe)
import            System.FilePath.Posix  ((</>), takeDirectory)
import            System.Directory       (createDirectoryIfMissing)
import            GHC.StaticPtr

type RealType = Double
type Bracket = (RealType, RealType)

data ProgramOptions = ProgramOptions
  { xMin          :: RealType
  , xMax          :: RealType
  , eps           :: RealType
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

createDirectories :: Cluster ()
createDirectories = do
  outputDir <- asks $ Slurm.output . clusterJobOptions
  liftIO $ maybe (return ()) 
                 (createDirectoryIfMissing True . takeDirectory) 
                 outputDir

rootBinarySearch :: (Monad m, MonadIO m) => Int -> RealType -> Bracket -> RealType -> m Bracket
rootBinarySearch n x brckt eps = 
  do
    Log.info "Running binary search at " (x, brckt, eps)
    let result = recurseBinary brckt
    Log.info "Computed bracket ------- " result
    return result
  where
    recurseBinary :: Bracket -> Bracket
    recurseBinary (down, up) | up-down < eps = (down, up)
                             | f mid >= x   = recurseBinary (down, mid)
                             | otherwise     = recurseBinary (mid, up)
      where 
        mid = (down + up) / 2
        f x = x^n

rootBinarySearchStatic :: StaticPtr (RemoteFunction (Int, RealType, Bracket, RealType) Bracket)
rootBinarySearchStatic = static (remoteFn $ uncurry4 rootBinarySearch)

runRemoteRootBinarySearch :: Int -> RealType -> Bracket -> RealType -> Job Bracket
runRemoteRootBinarySearch = curry4 $ remoteEval rootBinarySearchStatic

binarySearchJob :: Int -> [RealType] -> RealType -> Job [Bracket]
binarySearchJob n points eps = do
    Log.info "Computing inverse to x^n with n" n
    Log.info "Running binary searches at     " points
    Log.info "Stopping searches at precision " eps
    mapConcurrently (runSearchMemoized n) points
  where
    runSearch :: Int -> RealType -> Job Bracket
    runSearch n x = runRemoteRootBinarySearch n x (0, max 1 x) eps
    runSearchMemoized = curry $ memoizeWithMap kvmap $ uncurry runSearch
    kvmap = KeyValMap "binary_root_search"

binarySearchJobStatic :: StaticPtr (RemoteFunction ((Int, [RealType], RealType), ProgramInfo) [Bracket])
binarySearchJobStatic = static (remoteFnJob $ uncurry3 binarySearchJob)

runRemoteBinarySearchJob :: Int -> [RealType] -> RealType -> Cluster [Bracket]
runRemoteBinarySearchJob = curry3 $ remoteEvalJob binarySearchJobStatic

clusterComputation :: ProgramOptions -> Cluster ()
clusterComputation ProgramOptions{..} = do
  Log.text "Running an example computation"
  createDirectories
  let
    point i = fromIntegral i * (xMax - xMin)/(fromIntegral nPoints - 1) + xMin
    points = map point [0 .. nPoints-1]
    runRootNJob n = local (setJobType MPIJob{ mpiNodes = 2, mpiNTasksPerNode = 2 }) $
      runRemoteBinarySearchJob n points eps
  mapConcurrently_ runRootNJob [2,3,4]

main :: IO ()
main = hyperionMain programOpts mkHyperionConfig clusterComputation
