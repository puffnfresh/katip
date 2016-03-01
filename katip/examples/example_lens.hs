{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE TemplateHaskell            #-}
module Main
    ( main
    ) where


-------------------------------------------------------------------------------
import           Control.Lens         hiding ((.=))
import           Control.Monad.Reader
import           Data.Aeson
import           Data.Monoid          as M
-------------------------------------------------------------------------------
import           Katip
-------------------------------------------------------------------------------


data MyState = MyState {
    _msKNamespace :: Namespace
  , _msKContext   :: LogContexts
  , _msLogEnv     :: LogEnv
  }


-- This gives us HasMyState, which is helpful for complex stacks where
-- MyState may be nested somewhere deeper inside a larger data
-- structure. You can keep functions that operate on MyState as
-- general as possible.
makeClassy ''MyState


-------------------------------------------------------------------------------
-- | An example of advanced katip usage. Be sure to check out
-- lens_example for a slightly cleaner and more general pattern.
main :: IO ()
main = do
  s <- MyState M.mempty mempty <$> initLogEnv mempty (Environment "production")
  runStack s $ do
    $(logTM) InfoS "Started"
    addNamespace "confrabulation" $ addContext (ConfrabLogCTX 42) $ do
      $(logTM) DebugS "Confrabulating widgets, with extra namespace and context"
      confrabulateWidgets
    $(logTM) InfoS "Namespace and context are back to normal"


-------------------------------------------------------------------------------
newtype ConfrabLogCTX = ConfrabLogCTX Int


instance ToJSON ConfrabLogCTX where
  toJSON (ConfrabLogCTX factor) = object ["confrab_factor" .= factor]


instance ToObject ConfrabLogCTX


instance LogItem ConfrabLogCTX where
  payloadKeys _verb _a = AllKeys


-------------------------------------------------------------------------------
confrabulateWidgets :: (Monad m) => m ()
confrabulateWidgets = return ()


-------------------------------------------------------------------------------
newtype MyStack m a = MyStack {
      unStack :: ReaderT MyState m a
    } deriving (MonadReader MyState, Functor, Applicative, Monad, MonadIO)


instance (MonadIO m) => Katip (MyStack m) where
  getLogEnv = view msLogEnv


instance (MonadIO m) => KatipContext (MyStack m) where
  getKatipContext = view msKContext
  getKatipNamespace = view msKNamespace


-------------------------------------------------------------------------------
-- | Merge some context into the log only for the given block
addContext :: (LogItem i, MonadReader r m, HasMyState r) => i -> m a -> m a
addContext i = local (\r -> r & msKContext <>~ ctxs)
  where
    ctxs = liftPayload i


-------------------------------------------------------------------------------
-- | Add a layer of namespace to the logs only for the given block
addNamespace :: (MonadReader r m, HasMyState r) => Namespace -> m a -> m a
addNamespace ns = local (\r -> r & msKNamespace <>~ ns)


-------------------------------------------------------------------------------
runStack :: MyState -> MyStack m a -> m a
runStack s f = runReaderT (unStack f) s
