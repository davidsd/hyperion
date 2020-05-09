{-# LANGUAGE DeriveAnyClass     #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric      #-}

module Hyperion.ProgramId where

import           Data.Aeson                     (FromJSON, ToJSON)
import           Data.Binary                    (Binary)
import           Data.Data                      (Data)
import           Data.Text                      (Text, pack)
import qualified Database.SQLite.Simple.ToField as Sql
import           GHC.Generics                   (Generic)
import           Hyperion.Util                  (randomString)

newtype ProgramId = ProgramId Text
  deriving (Show, Eq, Ord, Generic, Data, Binary, FromJSON, ToJSON)

instance Sql.ToField ProgramId where
  toField = Sql.toField . programIdToText

programIdToText :: ProgramId -> Text
programIdToText (ProgramId t) = t

newProgramId :: IO ProgramId
newProgramId = fmap (ProgramId . pack) (randomString 5)
