{-# LANGUAGE CPP                        #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE StandaloneDeriving         #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE UndecidableInstances       #-}

-- | Provides support for treating payloads and namespaces as
-- composable contexts. The common pattern would be to provide a
-- 'KatipContext' instance for your base monad. When your program
-- changes to a more detailed context, say to the database, you can
-- use 'LogT' to tack on a typed context and a namespace
-- which will be merged into the enclosing monad's context and
-- namespace.
module Katip.Monadic
    (
    -- * Monadic variants of logging functions from "Katip.Core"
      logFM
    , logTM
    , logItemM
    , logExceptionM

    -- * Machinery for merging typed log payloads/contexts
    , KatipContext(..)
    , AnyLogContext
    , LogContexts
    , liftPayload
    ) where


-------------------------------------------------------------------------------
import           Control.Monad.Catch
import           Control.Monad.Trans.Class
import           Control.Monad.Trans.Either        (EitherT)
import           Control.Monad.Trans.Except        (ExceptT)
import           Control.Monad.Trans.Identity      (IdentityT)
import           Control.Monad.Trans.List          (ListT)
import           Control.Monad.Trans.Maybe         (MaybeT)
import           Control.Monad.Trans.Reader        (ReaderT)
import           Control.Monad.Trans.Resource      (ResourceT)
import           Control.Monad.Trans.RWS           (RWST)
import qualified Control.Monad.Trans.RWS.Strict    as Strict (RWST)
import           Control.Monad.Trans.State         (StateT)
import qualified Control.Monad.Trans.State.Strict  as Strict (StateT)
import           Control.Monad.Trans.Writer        (WriterT)
import qualified Control.Monad.Trans.Writer.Strict as Strict (WriterT)
import           Data.Aeson
import qualified Data.HashMap.Strict               as HM
import           Data.Monoid
import           Data.Text                         (Text)
import           Language.Haskell.TH
-------------------------------------------------------------------------------
import           Katip.Core
-------------------------------------------------------------------------------

-- | A wrapper around a log context that erases type information so
-- that contexts from multiple layers can be combined intelligently.
data AnyLogContext where
    AnyLogContext :: (LogItem a) => a -> AnyLogContext


-------------------------------------------------------------------------------
-- | Heterogeneous list of log contexts that provides a smart
-- 'LogContext' instance for combining multiple payload policies.
newtype LogContexts = LogContexts [AnyLogContext] deriving (Monoid)

instance ToJSON LogContexts where
    toJSON (LogContexts cs) =
      Object $ mconcat $ map (\(AnyLogContext v) -> toObject v) cs

instance ToObject LogContexts

instance LogItem LogContexts where
    payloadKeys verb (LogContexts vs) = mconcat $ map payloadKeys' vs
      where
        -- To ensure AllKeys doesn't leak keys from other values when
        -- combined, we resolve AllKeys to its equivalent SomeKeys
        -- representation first.
        payloadKeys' (AnyLogContext v) = case payloadKeys verb v of
          AllKeys -> SomeKeys $ HM.keys $ toObject v
          x       -> x


-------------------------------------------------------------------------------
-- | Lift a log context into the generic wrapper
liftPayload :: (LogItem a) => a -> LogContexts
liftPayload = LogContexts . (:[]) . AnyLogContext


-------------------------------------------------------------------------------
-- | A monadic context that has an inherant way to get logging
-- context and namespace. Examples include a web application monad or
-- database monad. Combine with 'LogT' to nest.
class Katip m => KatipContext m where
  getKatipContext :: m LogContexts
  getKatipNamespace   :: m Namespace

--TODO: is this INLINABLE?
#define TRANS(T) \
  instance (KatipContext m, Katip (T m)) => KatipContext (T m) where \
    getKatipContext = lift getKatipContext; \
    getKatipNamespace = lift getKatipNamespace

#define TRANS_CTX(CTX, T) \
  instance (CTX, KatipContext m, Katip (T m)) => KatipContext (T m) where \
    getKatipContext = lift getKatipContext; \
    getKatipNamespace = lift getKatipNamespace

TRANS(IdentityT)
TRANS(MaybeT)
TRANS(EitherT e)
TRANS(ListT)
TRANS(ReaderT r)
TRANS(ResourceT)
TRANS(Strict.StateT s)
TRANS(StateT s)
TRANS(ExceptT s)
TRANS_CTX(Monoid w, Strict.WriterT w)
TRANS_CTX(Monoid w,        WriterT w)
TRANS_CTX(Monoid w, Strict.RWST r w s)
TRANS_CTX(Monoid w,        RWST r w s)

deriving instance (Monad m, KatipContext m) => KatipContext (KatipT m)

-------------------------------------------------------------------------------
-- | Log with everything, including a source code location. This is
-- very low level and you typically can use 'logTM' in its
-- place. Automaticallysupplies payload and namespace.
logItemM
    :: (Applicative m, KatipContext m, Katip m)
    => Maybe Loc
    -> Severity
    -> LogStr
    -> m ()
logItemM loc sev msg = do
    ctx <- getKatipContext
    ns <- getKatipNamespace
    logItem ctx ns loc sev msg



-------------------------------------------------------------------------------
-- | Log with full context, but without any code
-- location. Automatically supplies payload and namespace.
logFM
  :: (Applicative m, KatipContext m, Katip m)
  => Severity
  -- ^ Severity of the message
  -> LogStr
  -- ^ The log message
  -> m ()
logFM sev msg = do
  ctx <- getKatipContext
  ns <- getKatipNamespace
  logF ctx ns sev msg


-------------------------------------------------------------------------------
-- | 'Loc'-tagged logging when using template-haskell is OK. Automatically supplies payload and namespace.
--
-- @$(logt) InfoS "Hello world"@
logTM :: ExpQ
logTM = [| logItemM (Just $(getLoc)) |]


-------------------------------------------------------------------------------
-- | Perform an action while logging any exceptions that may occur.
-- Inspired by 'onException`.
--
-- >>>> error "foo" `logExceptionM` ErrorS
logExceptionM
    :: (KatipContext m, MonadCatch m, Applicative m)
    => m a                      -- ^ Main action to run
    -> Severity                 -- ^ Severity
    -> m a
logExceptionM action sev = action `catchAll` \e -> f e >> throwM e
  where
    f e = logFM sev (msg e)
    msg e = ls ("An exception has occured: " :: Text) <> showLS e
