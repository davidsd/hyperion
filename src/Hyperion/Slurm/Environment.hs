{-# Language TypeApplications #-}

module Hyperion.Slurm.Environment where

import System.Environment (getEnv, lookupEnv)
import System.Process (readCreateProcess, shell)

getNTasksPerNode :: IO Int
getNTasksPerNode = fmap (read @Int) $ getEnv "SLURM_NTASKS_PER_NODE"

getJobNodes :: IO [String]
getJobNodes = fmap lines $
  readCreateProcess (shell "scontrol show hostnames $SLURM_JOB_NODELIST") ""

lookupHeadNode :: IO (Maybe String)
lookupHeadNode = lookupEnv "SLURMD_NODENAME"
