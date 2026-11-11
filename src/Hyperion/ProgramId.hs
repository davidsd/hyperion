{-# LANGUAGE DeriveAnyClass     #-}
{-# LANGUAGE DerivingStrategies #-}

module Hyperion.ProgramId where

import Data.Aeson                     (FromJSON, ToJSON)
import Data.Binary                    (Binary)
import Data.Text                      (Text, pack)
import Database.SQLite.Simple.ToField qualified as Sql
import GHC.Generics                   (Generic)
import Hyperion.OsString              (OsString, fromText)
import Hyperion.Util                  (randomString)

newtype ProgramId = ProgramId Text
  deriving stock (Show, Eq, Ord, Generic)
  deriving anyclass (Binary, FromJSON, ToJSON)

instance Sql.ToField ProgramId where
  toField = Sql.toField . programIdToText

programIdToText :: ProgramId -> Text
programIdToText (ProgramId t) = t

programIdToOsString :: ProgramId -> OsString
programIdToOsString = fromText . programIdToText

newProgramId :: IO ProgramId
newProgramId = fmap (ProgramId . pack) (randomString 5)
