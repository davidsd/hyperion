{-# LANGUAGE DeriveAnyClass    #-}
{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE OverloadedStrings #-}

module Hyperion.ObjectId where

import           Control.Monad.Catch    (MonadCatch)
import           Control.Monad.IO.Class (MonadIO)
import           Control.Monad.Reader   (MonadReader)
import           Data.Aeson             (FromJSON, ToJSON)
import           Data.Binary            (Binary)
import           Data.BinaryHash        (hashBase64Safe)
import qualified Data.Text              as Text
import           Data.Typeable          (Typeable)
import           GHC.Generics           (Generic)
import qualified Hyperion.Database      as DB

-- | An identifier for an object, useful for building filenames and
-- database entries.
newtype ObjectId = ObjectId String
  deriving (Eq, Ord, Generic, Binary, FromJSON, ToJSON)

-- | Convert an ObjectId to a String.
objectIdToString :: ObjectId -> String
objectIdToString (ObjectId i) = "Object_" ++ i

-- | Convert an ObjectId to Text.
objectIdToText :: ObjectId -> Text.Text
objectIdToText = Text.pack . objectIdToString

-- | The ObjectId of an object is the result of 'hashBase64Safe'. The
-- first time 'getObjectId' is called, it comptues the ObjectId and
-- stores it in the database before returning it. Subsequent calls
-- read the value from the database.
getObjectId
  :: ( Binary a
     , Typeable a
     , ToJSON a
     , DB.HasDB env
     , MonadReader env m
     , MonadIO m
     , MonadCatch m
     )
  => a -> m ObjectId
getObjectId = DB.memoizeWithMap
  (DB.KeyValMap "objectIds")
  (pure . ObjectId . hashBase64Safe)
