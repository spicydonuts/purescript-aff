module Test.Main where

import Prelude

import Control.Alt ((<|>))
import Control.Apply ((*>))
import Control.Monad.Aff (Aff(), runAff, later, later', forkAff, forkAll, Canceler(..), cancel, attempt, finally, apathize)
import Control.Monad.Aff.AVar (AVAR(), makeVar, makeVar', putVar, modifyVar, takeVar, killVar)
import Control.Monad.Aff.Console (log)
import Control.Monad.Aff.Par (Par(..), runPar)
import Control.Monad.Cont.Class (callCC)
import Control.Monad.Eff (Eff())
import Control.Monad.Eff.Console (CONSOLE())
import Control.Monad.Eff.Exception (EXCEPTION(), throwException, error)
import Control.Monad.Error.Class (throwError)
import Control.Monad.Rec.Class (tailRecM)

import Data.Array (replicate)
import Data.Either (Either(..), either)

type Test a = forall e. Aff (console :: CONSOLE | e) a
type TestAVar a = forall e. Aff (console :: CONSOLE, avar :: AVAR | e) a

test_sequencing :: Int -> Test Unit
test_sequencing 0 = log "Done"
test_sequencing n = do
  later' 100 (log (show (n / 10) ++ " seconds left"))
  test_sequencing (n - 1)

test_pure :: Test Unit
test_pure = do
  pure unit
  pure unit
  pure unit
  log "Success: Got all the way past 4 pures"

test_attempt :: Test Unit
test_attempt = do
  e <- attempt (throwError (error "Oh noes!"))
  either (const $ log "Success: Exception caught") (const $ log "Failure: Exception NOT caught!!!") e

test_apathize :: Test Unit
test_apathize = do
  apathize $ throwError (error "Oh noes!")
  log "Success: Exceptions don't stop the apathetic"

test_putTakeVar :: TestAVar Unit
test_putTakeVar = do
  v <- makeVar
  forkAff (later $ putVar v 1.0)
  a <- takeVar v
  log ("Success: Value " ++ show a)

test_killFirstForked :: Test Unit
test_killFirstForked = do
  c <- forkAff (later' 100 $ pure "Failure: This should have been killed!")
  b <- c `cancel` (error "Just die")
  log (if b then "Success: Killed first forked" else "Failure: Couldn't kill first forked")


test_killVar :: TestAVar Unit
test_killVar = do
  v <- makeVar
  killVar v (error "DOA")
  e <- attempt $ takeVar v
  either (const $ log "Success: Killed queue dead") (const $ log "Failure: Oh noes, queue survived!") e

test_finally :: TestAVar Unit
test_finally = do
  v <- makeVar
  finally
    (putVar v 0)
    (putVar v 2)
  apathize $ finally
    (throwError (error "poof!") *> putVar v 666) -- this putVar should not get executed
    (putVar v 40)
  n1 <- takeVar v
  n2 <- takeVar v
  n3 <- takeVar v
  log $ if n1 + n2 + n3 == 42 then "Success: effects amount to 42."
                                else "Failure: Expected 42."

test_parRace :: TestAVar Unit
test_parRace = do
  s <- runPar (Par (later' 100 $ pure "Success: Early bird got the worm") <|>
               Par (later' 200 $ pure "Failure: Late bird got the worm"))
  log s

test_parRaceKill1 :: TestAVar Unit
test_parRaceKill1 = do
  s <- runPar (Par (later' 100 $ throwError (error ("Oh noes!"))) <|>
               Par (later' 200 $ pure "Success: Early error was ignored in favor of late success"))
  log s

test_parRaceKill2 :: TestAVar Unit
test_parRaceKill2 = do
  e <- attempt $ runPar (Par (later' 100 $ throwError (error ("Oh noes!"))) <|>
                         Par (later' 200 $ throwError (error ("Oh noes!"))))
  either (const $ log "Success: Killing both kills it dead") (const $ log "Failure: It's alive!!!") e

test_semigroupCanceler :: Test Unit
test_semigroupCanceler =
  let
    c = Canceler (const (pure true)) <> Canceler (const (pure true))
  in do
    v <- cancel c (error "CANCEL")
    log (if v then "Success: Canceled semigroup composite canceler"
                     else "Failure: Could not cancel semigroup composite canceler")

test_cancelLater :: TestAVar Unit
test_cancelLater = do
  c <- forkAff $ (do pure "Binding"
                     _ <- later' 100 $ log ("Failure: Later was not canceled!")
                     pure "Binding")
  v <- cancel c (error "Cause")
  log (if v then "Success: Canceled later" else "Failure: Did not cancel later")

test_cancelPar :: TestAVar Unit
test_cancelPar = do
  c  <- forkAff <<< runPar $ Par (later' 100 $ log "Failure: #1 should not get through") <|>
                             Par (later' 100 $ log "Failure: #2 should not get through")
  v  <- c `cancel` (error "Must cancel")
  log (if v then "Success: Canceling composite of two Par succeeded"
                   else "Failure: Canceling composite of two Par failed")

loop :: forall eff. Int -> Aff (console :: CONSOLE | eff) Unit
loop n = tailRecM go n
  where
  go 0 = do
    log "Done!"
    return (Right unit)
  go n = return (Left (n - 1))

all :: forall eff. Int -> Aff (console :: CONSOLE, avar :: AVAR | eff) Unit
all n = do
  var <- makeVar' 0
  forkAll $ replicate n (modifyVar (+ 1) var)
  count <- takeVar var
  log ("Forked " <> show count)

cancelAll :: forall eff. Int -> Aff (console :: CONSOLE, avar :: AVAR | eff) Unit
cancelAll n = do
  canceler <- forkAll $ replicate n (later' 100000 (log "oops"))
  canceled <- cancel canceler (error "bye")
  log ("Cancelled all: " <> show canceled)

delay :: forall eff. Int -> Aff eff Unit
delay n = callCC \cont ->
  later' n (cont unit)

main :: Eff (console :: CONSOLE, avar :: AVAR, err :: EXCEPTION) Unit
main = runAff throwException (const (pure unit)) $ do
  log "Testing sequencing"
  test_sequencing 3

  log "Testing pure"
  test_pure

  log "Testing attempt"
  test_attempt

  log "Testing later"
  later $ log "Success: It happened later"

  log "Testing kill of later"
  test_cancelLater

  log "Testing kill of first forked"
  test_killFirstForked

  log "Testing apathize"
  test_apathize

  log "Testing semigroup canceler"
  test_semigroupCanceler

  log "Testing AVar - putVar, takeVar"
  test_putTakeVar

  log "Testing AVar killVar"
  test_killVar

  log "Testing finally"
  test_finally

  log "Testing Par (<|>)"
  test_parRace

  log "Testing Par (<|>) - kill one"
  test_parRaceKill1

  log "Testing Par (<|>) - kill two"
  test_parRaceKill2

  log "Testing cancel of Par (<|>)"
  test_cancelPar

  log "pre-delay"
  delay 1000

  log "post-delay"
  loop 1000000

  all 100000

  cancelAll 100000

  log "Done testing"
