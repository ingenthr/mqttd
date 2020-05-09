module Retention where

import           Control.Concurrent.STM
import           Control.Lens
import           Control.Monad          (when)
import           Control.Monad.IO.Class (MonadIO (..))
import           Control.Monad.Logger   (MonadLogger (..))
import qualified Data.ByteString.Lazy   as BL
import           Data.Map.Strict        (Map)
import qualified Data.Map.Strict        as Map
import           Data.Time.Clock        (UTCTime (..), addUTCTime, getCurrentTime)
import           Network.MQTT.Lens
import qualified Network.MQTT.Types     as T
import           UnliftIO               (MonadUnliftIO (..))

import           MQTTD.Util
import qualified Scheduler

data Retained = Retained {
  _retainTS  :: UTCTime,
  _retainExp :: Maybe UTCTime,
  _retainMsg :: T.PublishRequest
  } deriving Show

data Persistence = Persistence {
  _store   :: TVar (Map BL.ByteString Retained),
  _qrunner :: Scheduler.QueueRunner BL.ByteString
  }

newPersistence :: MonadIO m => m Persistence
newPersistence = Persistence <$> liftIO (newTVarIO mempty) <*> Scheduler.newRunner

cleanPersistence :: (MonadLogger m, MonadUnliftIO m) => Persistence -> m ()
cleanPersistence Persistence{..} = Scheduler.run cleanup _qrunner
    where
      cleanup k = liftIO getCurrentTime >>= \now -> liftSTM $ do
        r <- (_retainExp =<<) . Map.lookup k <$> readTVar _store
        when (r < Just now) $ modifyTVar' _store (Map.delete k)

persist :: MonadIO m => T.PublishRequest -> Persistence -> m ()
persist T.PublishRequest{_pubRetain=False} _ = pure ()
persist T.PublishRequest{_pubTopic,_pubBody=""} Persistence{..} =
  liftSTM $ modifyTVar' _store (Map.delete _pubTopic)
persist pr@T.PublishRequest{..} Persistence{..} = do
  now <- liftIO getCurrentTime
  let e = pr ^? properties . folded . _PropMessageExpiryInterval . to (absExp now)
  liftSTM $ modifyTVar' _store (Map.insert _pubTopic (Retained now e pr))
  maybe (pure ()) (\t -> Scheduler.enqueue t _pubTopic _qrunner) e

    where absExp now secs = addUTCTime (fromIntegral secs) now
