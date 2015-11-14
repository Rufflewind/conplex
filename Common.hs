{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeSynonymInstances #-}
module Common where
import Control.Arrow ((>>>), first, left)
import Control.Applicative
import Control.Concurrent (forkIO, killThread, threadDelay)
import Control.Concurrent.Async
import Control.Concurrent.MVar
import Control.Exception
import Control.Monad
import Control.Monad.Error.Class
import Control.Monad.Trans.Maybe
import Control.Monad.IO.Class
import Data.Foldable
import Data.Function ((&))
import Data.IntCast
import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Maybe (fromMaybe)
import Data.Monoid ((<>))
import Data.Sequence (Seq, ViewL((:<)), (|>))
import Data.Serialize
import Data.Tuple (swap)
import Data.Typeable (Typeable, typeRep)
import Data.Word (Word64, Word32)
import Foreign (Storable, sizeOf)
import System.IO
import qualified Data.Map.Strict as Map
import qualified Data.Sequence as Seq

{- DEBUG -}
import qualified System.GlobalLock as GLock

atomicPrintStderr :: String -> IO ()
atomicPrintStderr msg = GLock.lock $ do
  hPutStrLn stderr msg
  hFlush stderr

traceIO :: Show b => String -> b -> IO a -> IO a
traceIO name ctx action = do
  atomicPrintStderr ("++" <> name <> " " <> show ctx)
  result <- try action
  case result of
    Left e  -> do
      atomicPrintStderr ("!!" <> name <> " " <> show ctx <>
                         ": " <> show (e :: SomeException))
      throwIO e
    Right x -> do
      atomicPrintStderr ("--" <> name <> " " <> show ctx)
      pure x
-- END DEBUG -}

modifyMVarPure :: MVar a -> (a -> a) -> IO ()
modifyMVarPure v f = modifyMVar_ v (pure . f)

mapConcurrently_ :: Foldable t => (a -> IO ()) -> t a -> IO ()
mapConcurrently_ f = runConcurrently . traverse_ (Concurrently . f)

concurrently_ :: IO () -> IO () -> IO ()
concurrently_ x y = void (concurrently x y)

standby :: IO a
standby = forever (threadDelay 1000000000)

-- | Automatically restart if the action fails (after the given delay).
autorestart :: Int -> IO a -> IO a
-- this type signature is not ideal ^
autorestart delay action = do
  result <- tryAny action
  case result of
    Right x -> pure x
    Left  e -> do
      hPutStrLn stderr (show e)
      hFlush stderr
      threadDelay delay
      autorestart delay action

forkIO_ :: IO () -> IO ()
forkIO_ = void . forkIO

tryAny :: IO a -> IO (Either SomeException a)
tryAny action = do
  result <- newEmptyMVar
  mask $ \ unmask -> do
    thread <- forkIO (try (unmask action) >>= putMVar result)
    unmask (readMVar result) `onException` killThread thread

fromJustIO1 :: Exception e => (a -> e) -> (a -> Maybe b) -> a -> IO b
fromJustIO1 e f x = fromJustIO (e x) (f x)

fromJustIO :: Exception e => e -> Maybe a -> IO a
fromJustIO _ (Just x) = pure x
fromJustIO e Nothing  = throwIO e

fromJustE :: String -> Maybe a -> a
fromJustE e = fromMaybe (error e)

maybeToMonadError :: MonadError e m => e -> Maybe a -> m a
maybeToMonadError e = maybeToEither e >>> eitherToMonadError

eitherToMonadError :: MonadError e m => Either e a -> m a
eitherToMonadError (Left e)  = throwError e
eitherToMonadError (Right x) = pure x

eitherToMaybe :: Either e a -> Maybe a
eitherToMaybe (Right e) = Just e
eitherToMaybe (Left  _) = Nothing

maybeToAlternative :: Alternative f => Maybe a -> f a
maybeToAlternative Nothing  = empty
maybeToAlternative (Just x) = pure x

maybeToEither :: e -> Maybe a -> Either e a
maybeToEither e Nothing  = Left  e
maybeToEither _ (Just x) = Right x

generateBidiMap :: (Ord a, Ord b) => [(a, b)] -> (Map a b, Map b a)
generateBidiMap t = (Map.fromList t, Map.fromList (swap <$> t))

popMap :: Ord k => k -> Map k a -> Maybe (a, Map k a)
popMap k m = Map.lookup k m <&> \ x -> (x, Map.delete k m)

-- | Same as '<$>' but flips the order of the arguments.
{-# INLINE (<&>) #-}
infixl 1 <&>
(<&>) :: Functor f => f a -> (a -> b) -> f b
m <&> f = fmap f m

-- | Similar to 'sizeOf' but acts on a proxy value.
{-# INLINE sizeOfProxy #-}
sizeOfProxy :: Storable a => proxy a -> Int
sizeOfProxy = sizeOf . unproxy

-- | Restrict the type of the first argument based on a proxy value.
--   It otherwise behaves identical to 'const'.
{-# INLINE asTypeOfProxy #-}
asTypeOfProxy :: a -> proxy a -> a
asTypeOfProxy = const

-- | Construct a dummy value based on the type of a proxy value.
--   The dummy value must not be evaluated.
unproxy :: proxy a -> a
unproxy _ = error "unproxy: dummy value is not meant to be evaluated"

-- | A dummy value that must not be evaluated.
__ :: a
__ = error "__: dummy value is not meant to be evaluated"
