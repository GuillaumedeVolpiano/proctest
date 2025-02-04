{-# LANGUAGE DeriveDataTypeable #-}

{- | An IO library for testing interactive command line programs.

Read this first:

  - Tests using Proctests need to be compiled with @-threaded@ for not blocking on process spawns.

  - Beware that the Haskell GC closes process 'Handle's after their last use.
    If you don't want to be surprised by this, use 'hClose' where you want
    them to be closed (convenience: 'closeHandles').
    Really do this for EVERY process you create, the behaviour of a program
    writing to a closed handle is undefined. For example,
    'getProcessExitCode' run on such a program somtimes seems to
    always return 'ExitSuccess', no matter what the program actually does.

  - Make sure handle buffering is set appropriately.
    'run' sets 'LineBuffering' by default.
    Change it with 'setBuffering' or 'hSetBuffering'.

  - Do not run the program in a shell (e.g. 'runInteractiveCommand') if you want to
    be able to terminate it reliably ('terminateProcess'). Use processes without shells
    ('runInteractiveProcess') instead.


Example:

Let's say you want to test an interactive command line program like @cat@,
and integrate your test into a test framework like "Test.HSpec",
using "Test.HSpec.HUnit" for the IO parts (remember that Proctest /is/ stateful IO).

> main = hspec $ describe "cat" $ do
>
>   it "prints out what we put in" $ do
>
>     -- Start up the program to test
>     (hIn, hOut, hErr, p) <- run "cat" []
>
>     -- Make sure buffering doesn't prevent us from reading what we expect
>     -- ('run' sets LineBuffering by default)
>     setBuffering NoBuffering [hIn, hOut]
>
>     -- Communicate with the program
>     hPutStrLn hIn "hello world"
>
>     -- Define a convenient wrapper around 'waitOutput'.
>     --
>     -- It specifies how long we have to wait
>     -- (malfunctioning programs shall not block automated testing for too long)
>     -- and how many bytes we are sure the expected response fits into
>     -- (malfunctioning programs shall not flood us with garbage either).
>     let catWait h = asUtf8Str <$> waitOutput (seconds 0.01) 1000 h -- Wait max 10 ms, 1000 bytes
>
>     -- Wait a little to allow `cat` processing the input
>     sleep (seconds 0.00001)
>
>     -- Read the response
>     response <- catWait hOut
>
>     -- Test if it is what we want (here using HUnit's 'expectEqual')
>     response @?= "hello world\n"

-}

module Test.Proctest (
  -- * String conversion
  asUtf8
, asUtf8Str

 -- * Running and stopping programs
, ProcessHandles
, run
, RunException (..)
, isRunning
, terminateProcesses
, closeHandles
, closeProcessHandles

-- * Timeouts
, Timeout (NoTimeout)
, InvalidTimeoutError
, mkTimeoutUs
, mkTimeoutMs
, mkTimeoutS
, seconds

-- * Communicating with programs
, TimeoutException
, timeoutToSystemTimeoutArg
, withTimeout
, waitOutput
, waitOutputNoEx
, setBuffering
, sleep

-- * Convenience module exports
, module System.Exit
, module System.IO
, module System.Process
) where

import Control.Concurrent (threadDelay)
import Control.Exception (Exception (..), throw, throwIO)
import Data.Text (Text, unpack)
import Data.Text.Encoding (decodeUtf8)
import Data.Typeable
import qualified Data.ByteString as BS
import System.Exit
import System.IO
import System.Process
import qualified System.Timeout (timeout)


-- | Treats a 'BS.ByteString' as UTF-8 decoded 'Text'.
asUtf8 :: BS.ByteString -> Text
asUtf8 = decodeUtf8

-- | Treats a 'BS.ByteString' as UTF-8 decoded 'String'.
asUtf8Str :: BS.ByteString -> String
asUtf8Str = unpack . asUtf8


-- | Short cut. ALWAYS use the order stdin, stdout, stderr, process handle.
type ProcessHandles = (Handle, Handle, Handle, ProcessHandle)


-- | Runs a program with the given arguemtns.
--
-- Returns @(stdout, stderr, stdin, process)@. See 'runInteractiveProcess'.
--
-- Directly runs the process, does not use a shell.
--
-- Sets the 'BufferMode to 'LineBuffering' if successful.
--
-- Throws 'CommandNotFound' if the command doesn't exist.
-- Due to 'createProcess' not throwing an exception
-- (<http://www.haskell.org/pipermail/haskell-cafe/2012-August/102824.html>),
-- this is currently implemented by checking if the program
-- returns early with error code 127.
run :: FilePath -> [String] -> IO (Handle, Handle, Handle, ProcessHandle)
run cmd args = do
  r@(i, o, e, p) <- runInteractiveProcess cmd args Nothing Nothing
  getProcessExitCode p >>= \me -> case me of
    -- TODO see if we can make runInteractiveProcess throw the exception instead
    Just (ExitFailure 127) -> throwIO $ CommandNotFound cmd
    _                      -> do
      setBuffering LineBuffering [i, o, e]
      return r

-- | Exception to be thrown when a program could not be started.
data RunException = CommandNotFound String
                    deriving (Show, Typeable)

instance Exception RunException

-- | Tells whether the given process is still running.
isRunning :: ProcessHandle -> IO Bool
isRunning p = do x <- getProcessExitCode p; return (x == Nothing)

-- | Terminates all processes in the list.
terminateProcesses :: [ProcessHandle] -> IO ()
terminateProcesses = mapM_ terminateProcess

-- | Closes all handles in the list.
closeHandles :: [Handle] -> IO ()
closeHandles = mapM_ hClose

-- | Closes all file handles to all given handle-process-tuples.
--
-- Use this to make sure that handles are not closed due to garbage
-- collection (see "System.IO") while your processes are still running.
--
-- It is safe to call this on processes which have already exited.
closeProcessHandles :: [ProcessHandles] -> IO ()
closeProcessHandles = mapM_ $ \(i, o, e, _) -> closeHandles [i, o, e]


-- | A microsecond timeout, or 'NoTimeout'.
data Timeout = Micros Int | NoTimeout deriving (Eq, Ord, Show)

-- | An error to be thrown if something is to be converted into 'Timeout'
-- that does not fit into 'Int'.
data InvalidTimeoutError = InvalidTimeoutError String deriving (Show, Typeable)

instance Exception InvalidTimeoutError

-- | Turns the given number of microseconds into a 'Timeout'.
--
-- Throws an exception on 'Int' overflow.
mkTimeoutUs :: Integer -> Timeout
mkTimeoutUs n
  | n <= 0                             = NoTimeout
  | n > fromIntegral (maxBound :: Int) = throw $ InvalidTimeoutError msg
  | otherwise                          = Micros (fromIntegral n)
  where
    msg = "Test.Proctest.Timeout: " ++ show n ++ " microseconds do not fit into Int"


-- | Turns the given number of milliseconds into a 'Timeout'.
--
-- Throws an exception on 'Int' overflow.
mkTimeoutMs :: (Integral a) => a -> Timeout
mkTimeoutMs = mkTimeoutUs . (* 1000) . fromIntegral


-- | Turns the given number of seconds into a 'Timeout'.
--
-- Throws an exception on 'Int' overflow.
mkTimeoutS :: (Integral a) => a -> Timeout
mkTimeoutS = mkTimeoutUs . (* 1000000) . fromIntegral


-- | Turns floating seconds into a 'Timeout'.
--
-- Throws an exception on 'Int' overflow.
--
-- Example: @(seconds 0.2)@ are roughly @Micros 200000@.
seconds :: Double -> Timeout
seconds s = mkTimeoutUs (round $ s * 1000000)


-- | Suspends execution for the given timeout; uses 'threadDelay' internally.
-- For 'NoTimeout', threadDelay will not be called.
sleep :: Timeout -> IO ()
sleep t = case t of
  NoTimeout -> return ()
  Micros n  -> threadDelay n


-- | Exception to be thrown when a program did not terminate
-- within the expected time.
data TimeoutException = TimeoutException deriving (Show, Typeable)

instance Exception TimeoutException


-- | Converts a 'Timeout' milliseconds suitable to be passed into 'timeout'.
timeoutToSystemTimeoutArg :: Timeout -> Int
timeoutToSystemTimeoutArg t = case t of
  Micros n  -> n
  NoTimeout -> -1


-- | Overflow-safe version of 'System.Timeout.timeout', using 'Timeout'.
withTimeout :: Timeout -> IO a -> IO (Maybe a)
withTimeout t = System.Timeout.timeout (timeoutToSystemTimeoutArg t)


-- | Blocking wait for output on the given handle.
--
-- Returns 'Nothing' timeout is exceeded.
waitOutputNoEx :: Timeout                   -- ^ Timeout after which reading output will be aborted.
               -> Int                       -- ^ Maximum number of bytes after which reading output will be aborted.
               -> Handle                    -- ^ The handle to read from.
               -> IO (Maybe BS.ByteString)  -- ^ What was read from the handle.
waitOutputNoEx t maxBytes handle =
  withTimeout t (BS.hGetSome handle maxBytes)


-- | Blocking wait for output on the given handle.
--
-- Throws a 'TimeoutException' if the timeout is exceeded.
--
-- Based on 'waitOutputNoEx'.
waitOutput :: Timeout           -- ^ Timeout after which reading output will be aborted.
           -> Int               -- ^ Maximum number of bytes after which reading output will be aborted.
           -> Handle            -- ^ The handle to read from.
           -> IO BS.ByteString  -- ^ What was read from the handle.
waitOutput t maxBytes handle = let ex = throwIO TimeoutException in
  waitOutputNoEx t maxBytes handle >>= maybe ex return


-- | Sets the buffering of the all given handles to the given 'BufferMode'.
setBuffering :: BufferMode -> [Handle] -> IO ()
setBuffering bufferMode handles = mapM_ (flip hSetBuffering bufferMode) handles
