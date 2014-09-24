{-# LANGUAGE ScopedTypeVariables, TemplateHaskell #-}

module BankAccountDefs (
  BankAccount(..),
  deposit, depositCtrt,
  withdraw, withdrawCtrt,
  getBalance, getBalanceCtrt,
  Operation(..),
) where

import Database.Cassandra.CQL as CQL
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Serialize as S
import Data.Word (Word8)
import Control.Applicative ((<$>))
import Codeec.Types
import Codeec.Contract
import Codeec.TH
import Debug.Trace

data BankAccount = Deposit_ Int | Withdraw_ Int | GetBalance_ deriving Show

instance Serialize BankAccount where
  put (Deposit_ v) = putTwoOf S.put S.put (0::Word8, v)
  put (Withdraw_ v) = putTwoOf S.put S.put (1::Word8, v)
  put (GetBalance_) = error "serializing GetBalance"
  get = do
    (i::Word8,v::Int) <- getTwoOf S.get S.get
    case i of
      0 -> return $ Deposit_ v
      1 -> return $ Withdraw_ v
      otherwise -> error "deserializing GetBalance"

instance CasType BankAccount where
  getCas = do
    r <- decode . unBlob <$> getCas
    case r of
      Left _ -> error "Parse fail"
      Right v -> return $ v
  putCas = putCas . Blob . encode
  casType _ = CBlob

type Res a = (a, Maybe BankAccount)

deposit :: [BankAccount] -> Int -> Res ()
deposit _ amt = ((), Just $ Deposit_ amt)


withdraw :: [BankAccount] -> Int -> Res Bool
withdraw ctxt amt =
  let (bal, _) = getBalance ctxt ()
  in if bal > amt
     then (True, Just $ Withdraw_ amt)
     else (False, Nothing)

getBalance :: [BankAccount] -> () -> Res Int
getBalance ops () =
  let v = {- trace ("GB : #effect=" ++ (show $ length ops)) -} foldl acc 0 ops
  in (v, Nothing)
  where
    acc s (Deposit_ i) = s + i
    acc s (Withdraw_ i) = s - i
    acc s GetBalance_ = s

instance Effectish BankAccount where
  summarize ctxt =
    let (v, _) = getBalance ctxt ()
    in [Deposit_ v]

mkOperations [''BankAccount]

depositCtrt :: Contract Operation
depositCtrt x = liftProp $ true

withdrawCtrt :: Contract Operation
withdrawCtrt x = forallQ_ [Deposit] $ \a -> forallQ_ [Withdraw] $ \b ->
                 forallQ_ [Withdraw] $ \c -> liftProp $
                    ((vis a b ∧ vis b x) ⇒ vis a x) ∧
                    (vis c x ∨ vis x c ∨ appRel Sameeff x c)

getBalanceCtrt :: Contract Operation
getBalanceCtrt x = forallQ_ [Deposit] $ \a -> forallQ_ [Withdraw] $ \b -> liftProp $
                      (vis a b ∧ vis b x) ⇒ vis a x
