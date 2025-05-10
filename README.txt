Distributed Algorithms Project 

Students: Jessica Pollard and Matthew Pham
Topic: snapshots
Programming Language: Odin

Overview:
This project involved the creation of a basic multiplayer game that can be saved at any point by the host using Mattern's snapshot algorithm.

Structure:
- connect contains the main.odin game file which contains all logic surrounding the game mechanics and snapshot loading / saving
- connect also contains the game_packet.odin file which defines the UDP based network layer of the program 
- server contains the server code that can be ran on a dedicated pc to act as a matchmaking server

Running the program:
The program can be run using the following commands from the root directory of the project (where client.exe is located):

1. start the host `./connect <port> <lobby id> Host`
2. in another terminal add a player `./connect <port> <lobby id> Join` -> up to 3 other players can join the host's lobby

Running the program from a save file:
The program can be ran with an existing save file, however it must have the same number of players as were in the saved lobby.

1. start the host `./connect <port> <lobby id> Host SAVE`
2. in another terminal add a player `./connect <port> <lobby id> Join` -> up to 3 other players can join the host's lobby

Game controls:
- 'w' -> move up
- 'a' -> move left
- 's' -> move down
- 'd' -> move right
- hold 'q' to carry a fence, release to place fence
- 'e' -> attack
- 'p' -> on the host this will trigger the snapshot algorithm and save the game

Functions related to snapshot algorithm:
- load_network
- wait_for_load_save
- should_snapshot
- partial_snapshot_ready
- game_save_start 
- game_save_is_complete
- game_save_complete
- delete_game_save
- take_state_snapshot
- partial_snapshot_create_and_send
- first_marker 
- another_marker


