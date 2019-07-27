{-# LANGUAGE DuplicateRecordFields #-}

module Hyperion.Slurm.JobId where

import           Data.Text       (Text)

data JobId
  = JobById Text
  | JobByName Text
  deriving (Show, Eq, Ord)
