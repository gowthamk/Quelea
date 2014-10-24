{-# LANGUAGE TemplateHaskell, ScopedTypeVariables #-}

import Codeec.Shim
import Codeec.ClientMonad
import Codeec.DBDriver
import BankAccountDefs
import Codeec.Contract
import System.Process (runCommand, terminateProcess)
import System.Environment (getExecutablePath, getArgs)
import Control.Concurrent (threadDelay)
import Codeec.NameService.SimpleBroker
import Codeec.Marshall
import Codeec.TH
import Database.Cassandra.CQL
import Control.Monad.Trans (liftIO)
import Data.Text (pack)
import Codeec.Types (summarize)
import Control.Monad (replicateM_, forever, when)
import Data.IORef
import Control.Concurrent

fePort :: Int
fePort = 5558

bePort :: Int
bePort = 5559


data Kind = B | C | S | D | Drop deriving (Read, Show)

keyspace :: Keyspace
keyspace = Keyspace $ pack "Codeec"

dtLib = mkDtLib [(Deposit, mkGenOp deposit summarize, $(checkOp Deposit depositCtrt)),
                 (Withdraw, mkGenOp withdraw summarize, $(checkOp Withdraw withdrawCtrt)),
                 (GetBalance, mkGenOp getBalance summarize, $(checkOp GetBalance getBalanceCtrt))]

main :: IO ()
main = do
  (kindStr:_) <- getArgs
  let k :: Kind = read kindStr
  case k of
    B -> startBroker (Frontend $ "tcp://*:" ++ show fePort)
                     (Backend $ "tcp://*:" ++ show bePort)
    S -> do
      runShimNode dtLib [("localhost","9042")] keyspace
        (Backend $ "tcp://localhost:" ++ show bePort) 5560
    C -> do
      iter <- newIORef (0::Int)
      mv::(MVar Int)<- newEmptyMVar
      replicateM_ 128 $ forkIO $ runSession (Frontend $ "tcp://localhost:" ++ show fePort) $ do
        forever $ do
          key <- liftIO $ newKey
          r::() <- invoke key Deposit (1::Int)
          r::Int <- invoke key GetBalance ()
          c <- liftIO $ atomicModifyIORef iter (\c -> (c+1,c+1))
          when (c `mod` 100 == 0) (liftIO . putStrLn $ "iter=" ++ show c ++ " count=" ++ show r)
        liftIO $ putMVar mv 0
      takeMVar mv
      return ()
    D -> do
      pool <- newPool [("localhost","9042")] keyspace Nothing
      runCas pool $ createTable "BankAccount"
      progName <- getExecutablePath
      putStrLn "Driver : Starting broker"
      b <- runCommand $ progName ++ " B"
      putStrLn "Driver : Starting server"
      s <- runCommand $ progName ++ " +RTS -N16 -RTS S"
      threadDelay 2000000
      putStrLn "Driver : Starting client"
      c <- runCommand $ progName ++ " +RTS -N16 -RTS C"
      threadDelay 60000000
      mapM_ terminateProcess [b,s,c]
      runCas pool $ dropTable "BankAccount"
    Drop -> do
      pool <- newPool [("localhost","9042")] keyspace Nothing
      runCas pool $ dropTable "BankAccount"
