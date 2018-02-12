
{-# LANGUAGE LambdaCase,RecordWildCards, OverloadedStrings #-} 
module Main where
  
  import System.Exit
  import System.IO
  import Control.Exception
  import System.Environment
  import Control.Monad (forever,replicateM,when,join)
  import Control.Monad.Fix (fix)
  import Control.Applicative
  import Control.Concurrent (forkFinally)
  import Control.Concurrent.STM
  import Control.Concurrent.Async
  import Text.Printf (hPrintf, printf)
  import Data.Map (Map)
  import qualified Data.Map as M
  import Data.Set (Set)
  import Data.String
  import Network
  import Network (PortID(..), accept, listenOn, withSocketsDo)
  import qualified Data.Set as S
  import Data.Hashable

  
  type ClientName = String
  type RoomName = String

  killSERV :: String
  killSERV = "KILL_SERVICE"


  data Message = Notice String
      | Tell String 
      | Broadcast String 
      | Command [[String]] String 
      | Error String String 
      deriving Show



  data Client = Client
      { clientName :: ClientName
      , clientChan :: TChan Message
      , clientHandle :: Handle 
      , clientID :: Int
  }
  
  data Room = Room
      { roomName :: RoomName
      , roomID :: Int
      , clients :: TVar (Map Int Client) -- Store list of clients in room particular room
  }
  

  type Server = TVar (Map Int Room)-- Store list of rooms

  newServer :: IO Server
  newServer = newTVarIO M.empty

  main :: IO()
  main = withSocketsDo $ do
      port <- getArgs
      let portNum = read $ head port :: Int
      server <- newServer
      putStrLn "waiting for connction"
      sock <- listenOn (PortNumber (fromIntegral portNum))
      
      forever $ do 
            (handle, host, port) <- accept sock
            printf "Connection accepted: %s\n" host
            forkFinally (handleClient handle server portNum) (\_ -> hClose handle) --fork each client to its own thread
      



  createClient :: ClientName -> Handle -> Int -> IO Client
  createClient name handle nameHash = do
      chan <- newTChanIO
      printf "Creating Client\n"
      return Client { clientName = name
                    , clientChan = chan
                    , clientHandle = handle
                    , clientID = nameHash
                    }

  sendMsg :: Client -> Message -> STM ()
  sendMsg Client{..} = writeTChan clientChan  -- {..} pattern matching so clientChan is easily accesible 
      
  sendMsgtoRoom :: Message -> Room -> IO ()
  sendMsgtoRoom msg room@Room{..} = atomically $ do 
      clientList <- readTVar clients --return a list of clients in a room from clients TVar
      let roomClients = M.elems clientList --access properties of clients
      mapM_ (\a -> sendMsg a msg) roomClients --send the message to each member in the room
  
  handleMsg :: Server -> Client -> Message -> IO Bool
  handleMsg serv client@Client{..} msg = 
      case msg of 
            Notice message -> output message
            Tell message -> output message
            Broadcast message -> output message
            Error head message -> output $ "->" ++ head ++ "<-\n" ++ message
            Command message arg -> case message of --depending on contents of message do one of the following
                  [["CLIENT_IP:",_],["PORT:",_],["CLIENT_NAME:",name]] -> do
                        putStrLn "client joined chatroom\n"
                        joinChatRoom client serv arg 
                        let joinmsg = "CHAT:" ++ show (hash arg) ++"\nCLIENT_NAME:" ++ name ++ "\nMESSAGE: " ++ name ++ " has joined the chatroom.\n" 
                        tellRoom (hash arg) (Broadcast joinmsg) --tell room client has joined
                        putStrLn "Room notified. returning True.\n"
                        return True
                  [["JOIN_ID:",id],["CLIENT_NAME:",name]] -> do
                        putStrLn "leave chatroom\n"
                        leaveChatroom client serv (read arg :: Int) (read id :: Int) 
                        return True 
                  [["PORT:",_],["CLIENT_NAME:",name]] -> do
                        let leavemsg = "CHAT:" ++ show (hash ("room1" :: String)) ++"\nCLIENT_NAME:" ++ name ++ "\nMESSAGE: " ++ name ++ " has left the chatroom.\n" --tried hard coding as cannot get disconnect message to send correct room name to all clients. 
                        tellRoom (read arg :: Int) (Tell leavemsg) 
                        removeClient serv client
                        return False
                  [["JOIN_ID:",id],["CLIENT_NAME:",name],("MESSAGE:":msgToSend),[]] -> do
                        putStrLn "send msg\n"
                        tellRoom (read arg :: Int) $ Tell ("CHAT:" ++ arg ++ "\nCLIENT_NAME: " ++ name ++ "\nMESSAGE: "++(unwords msgToSend)++"\n") --send message from client to room
                        return True
                  [["KILL_SERVICE"]] -> do
                        putStrLn "KILL\n"
                        if arg == killSERV then return False --Not correctly closing all handles
                        else return True
                  _ -> do
                        printf "Error\n"
                        atomically   $ sendMsg client $ Error "Error " "Unrecognised args"
                        return True
                  where 
                        tellRoom roomID msg = do
                              roomsList <- atomically $ readTVar serv
                              let maybeRoom = M.lookup roomID roomsList
                              case maybeRoom of
                                Nothing    -> return True
                                Just a -> sendMsgtoRoom msg a >> return True
            where output s = do putStrLn (clientName ++ "msg = " ++ s) >> hPutStrLn clientHandle s; return True

  
  handleClient :: Handle -> Server -> Int -> IO()
  handleClient handle server portNum = do
      printf "handling client\n"
      hSetNewlineMode handle universalNewlineMode
      hSetBuffering handle NoBuffering
      readNxt--read msg from client and deal with it accordingly 
      return ()
      where
            readNxt = do 
                  nxt <- hGetLine handle
                  case words nxt of 
                    ["HELO", "BASE_TEST"] -> do
                              sendHandle $ "HELO text\nIP: 0\nPort: " ++ (show portNum) ++ "\nStudentID: 14313812\n"
                              printf "Sending: Helo text\nIP: 0\nPort: portNum\nStudentID: 14313812\n"
                              readNxt
                    ["JOIN_CHATROOM:", roomName] -> do
                              arguments <- getArgs (3) -- get info from join message
                              case map words arguments of -- get details of join
                                    [["CLIENT_IP:",_],["PORT:",_],["CLIENT_NAME:",name]] -> do
                                          printf "joining chatroom\n"
                                          client <- createClient name handle (hash name) -- name may not be unique so use hash for client ID
                                          joinChatRoom client server roomName
                                          let joinmsg = "CHAT:" ++ show (hash roomName) ++"\nCLIENT_NAME:" ++ name ++ "\nMESSAGE: " ++ name ++ " has joined the chatroom.\n"
                                          tellRoom (hash roomName) $ Broadcast joinmsg
                                          let leavemsg = "CHAT:" ++ show (hash roomName) ++"\nCLIENT_NAME:" ++ name ++ "\nMESSAGE: " ++ name ++ " has left the chatroom once and for all.\n"
                                          runClient server client `finally` (tellRoom' (hash roomName) (Broadcast leavemsg) >>  removeClient server client >> return ()) -- run until client removed from chat.
                                    _ -> readNxt --if something else then get next message (for case of blank message)
                                    where
                                          tellRoom roomID msg = do
                                                roomList <- atomically $readTVar server
                                                let maybeR = M.lookup roomID roomList
                                                case maybeR of 
                                                      Nothing -> putStrLn ("That room does not exist\n" ++ show roomID) >> return True
                                                      Just a -> sendMsgtoRoom msg a >> return True
                                          tellRoom' roomID msg = do --
                                                roomList <- atomically $readTVar server
                                                let rKeys = M.keys roomList
                                                putStrLn (show rKeys)
                                                let key = rKeys!!1
                                                let maybeK = M.lookup key roomList
                                                case maybeK of 
                                                      Nothing -> putStrLn ("That room does not exist\n" ++ show roomID) >> return True
                                                      Just a -> sendMsgtoRoom msg a >> return True --Find client room one and send msg to that room
                    ["KILL_SERVICE"] -> do 
                        printf "Killing client\n"
                        hPutStrLn handle "see ya" >> exitSuccess --return

                    _ -> do
                        putStrLn $ "words are: " ++ show nxt ++ "\n"
                        readNxt

                  where
                        sendHandle s = hPutStrLn handle s
                        getArgs n = replicateM n (hGetLine handle)
                        

                              
  runClient :: Server -> Client -> IO()
  runClient serv client@Client{..} = do
      putStrLn "running client\n"
      race server recieve -- concurrently do server and recieve
      putStrLn "race done\n"
      tellRoom' 
      return ()
      where 
            recieve = forever $ do
                  putStrLn "in runClient doing case\n"
                  nxt <- hGetLine clientHandle 
                  case words nxt of
                        ["JOIN_CHATROOM:",roomName] -> do
                              putStrLn "running client joining chat\n"
                              restOfMsg <- getArgs (3)
                              sendToRoom restOfMsg roomName
                        ["LEAVE_CHATROOM:",roomID] -> do
                              putStrLn "running client leaving chat\n"
                              restOfMsg <- getArgs (2)
                              sendToRoom restOfMsg roomID
                        ["DISCONNECT:",ip] -> do
                              putStrLn "running client disconnect\n"
                              restOfMsg <- getArgs (2)
                              sendToRoom restOfMsg ip
                        ["CHAT:",roomID]-> do
                              putStrLn "running client chat\n"
                              restOfMsg <- getArgs (4)
                              sendToRoom restOfMsg roomID
                        ["KILL_SERVICE"] -> do
                              putStrLn "running client kill service\n"
                              sendToRoom [killSERV] killSERV
                              return()
                        _ -> do
                              putStrLn "error run client\n"
                              sendErrorToRoom 
                              
                        where 
                              getArgs n = replicateM n $ hGetLine clientHandle
                              sendToRoom msg roomName = atomically $ sendMsg client $ Command (map words msg) roomName
                              sendErrorToRoom  = atomically $ sendMsg client $ Error "Error 1" "No info in message"
  
            server = join $ atomically $ do 
                  msg <- readTChan clientChan
                  return $ do 
                        putStrLn "handeling message\n"
                        continue <- handleMsg serv client msg
                        putStrLn "handeling message returned\n"
                        when continue $ server
            tellRoom' = do
                  roomList <- atomically $readTVar serv
                  let rKeys = M.keys roomList
                  putStrLn (show rKeys)
                  let key = rKeys!!1 -- send leave message to client. I couldnt access the order in which it was leaving rooms so attempted to hard code.
                  let maybeK  = M.lookup key roomList
                  case maybeK of 
                        Nothing -> putStrLn ("That room does not exist!!!\n") >> return True
                        Just a -> do
                             let leavemsg = "CHAT:" ++ show (hash (roomName a)) ++"\nCLIENT_NAME:" ++ clientName ++ "\nMESSAGE: " ++ clientName ++ " has left the chatroomFINALLY.\n"
                             hPutStrLn clientHandle leavemsg >> return True

  removeClient :: Server -> Client -> IO() 
  removeClient serv client@Client{..} = do 
      roomsRemove <- atomically $ readTVar serv
      let rooms = Prelude.map (\room -> roomName room)(M.elems roomsRemove)
      let roomType = M.elems roomsRemove
      mapM_ (\room -> leave room ) rooms 
      where
            leave room = do 
                  leaveChatroom' client serv (hash room) >> putStrLn (clientName ++ " removed from " ++ room)

  newChatroom :: Client -> String -> STM Room
  newChatroom joiningClient@Client{..} room = do
      clientList <- newTVar $ M.insert clientID joiningClient M.empty
      return Room { roomName = room
                  , roomID = hash room
                  , clients = clientList
                  }


  joinChatRoom ::  Client -> Server -> String -> IO()
  joinChatRoom clientJoining@Client{..} serverRooms rName = atomically $ do
      roomList <- readTVar serverRooms
      case M.lookup (hash rName) roomList of --check if that chatroom exists
            Nothing -> do
                  room <- newChatroom clientJoining rName
                  let addRoomList = M.insert (roomID room) room roomList
                  writeTVar serverRooms addRoomList --add new chatroom to list of chatrooms
                  send (roomID room) (roomName room)
            Just a -> do
                  clientList <- readTVar (clients a)
                  let addClientList = M.insert clientID clientJoining clientList
                  writeTVar (clients a) addClientList
                  send (roomID a) (roomName a)
            where
                  send ref name = sendMsg clientJoining (Tell $ "JOINED_CHATROOM: "++name++"\nSERVER_IP: 0.0.0.0\nPORT: 0\nROOM_REF: " ++ show ref ++"\nJOIN_ID: " ++ show (ref+clientID)) --maybe \n?


  leaveChatroom' :: Client -> Server -> Int -> IO()
  leaveChatroom' client@Client{..} server roomID = leaveChatroom client server roomID (roomID+clientID)

  leaveChatroom :: Client -> Server -> Int -> Int -> IO()
  leaveChatroom client@Client{..} server roomID joinID = do
      rooms <- atomically $ readTVar server
      case M.lookup roomID rooms of 
            Nothing -> putStrLn "There is no room with that name" 
            Just a -> do
                  atomically $ sendMsg client (Tell $ "LEFT_CHATROOM:" ++ show roomID ++ "\nJOIN_ID:" ++ show joinID) --maybe \n?
                  removeClientfrmRoom 
                  putStrLn $ clientName ++ " left " ++ (roomName a)
                  where
                        removeClientfrmRoom = atomically $ do 
                              clientList <- readTVar (clients a)
                              let roomClients = M.elems clientList
                              mapM_ (\a -> sendMsg a leaveMsg) roomClients
                              let newClientList = M.delete (hash clientName) clientList
                              writeTVar (clients a) newClientList
                              
                        leaveMsg = (Broadcast $ "CHAT:" ++ show roomID ++ "\nCLIENT_NAME:" ++ clientName ++ "\nMESSAGE:" ++ clientName ++" has left the building.\n")

  deleteChatroom :: Server -> Int -> IO()
  deleteChatroom serv refID = atomically $ do
      roomsList <- readTVar serv
      case M.lookup refID roomsList of 
            Nothing -> return ()
            Just a -> do
                  let newroomsList = M.delete refID roomsList
                  writeTVar serv newroomsList
