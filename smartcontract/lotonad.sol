pragma solidity 0.8.24;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/utils/Base64.sol";


contract Lotonad is ERC721, Ownable, ReentrancyGuard {
    using Strings for uint256;

    /*─────────  Constants  ─────────*/
    uint256 public constant MAX_TICKETS_PER_GAME3 = 100; // Maximum cards per game
    uint256 public constant TICKET_PRICE = 0.1 ether;    // Card price
    uint256 public constant MINTING_DURATION = 4 minutes; // 10 minutes for minting
    uint256 public constant DRAW_INTERVAL = 3 seconds;   // New number every 10 seconds

    uint256 public constant PUBLIC_CLAIM_GRACE = 3 minutes;
    uint256 public constant OPEN_CLAIM_WINNER = type(uint256).max;

    /*─────────  Game state  ─────────*/
    uint256 public currentGameId = 0; // Start from 0; the first game will be 1
    uint256 private _tokenIdCounter;  // Token counter

    mapping(uint256 => uint256) public gameStartTime; // Mint start time for each game
    mapping(uint256 => bytes32) public gameSeed;      // Seed for draw generation
    mapping(uint256 => uint256) public prizePool;     // Game prize pool
    mapping(uint256 => uint256) public winnerToken;   // Winner token ID (0 if not set)

    /*─────────  Card data  ─────────*/
    mapping(uint256 => uint256) public tokenToGameId;    // Which game the token belongs to
    mapping(uint256 => uint8[10]) public tokenToNumbers; // 10 numbers for each token
    mapping(address => uint256[]) public playerTickets;  // Player's cards
    mapping(uint256 => mapping(address => bool)) public hasMintedInGame; // Whether the player minted in the game
    mapping(uint256 => uint256) public mintedCountPerGame; // Mint count per game
    mapping(uint256 => uint256) public claimAttempts;      // Claim attempts

    uint8 public constant MAX_CLAIM_ATTEMPTS = 3;

    /*─────────  Events  ─────────*/
    event NewGame(uint256 indexed gameId, uint256 startTime);
    event WinnerSelected(uint256 indexed gameId, uint256 tokenId);
    event AttemptFailed(uint256 indexed gameId, uint256 tokenId);

    constructor() ERC721("LotonadTicket", "LTT") Ownable(msg.sender) 
    {
        _tokenIdCounter = 1;
        _prepareNewGame();
    }

    function mintTicket() external payable nonReentrant {
        require(!hasMintedInGame[currentGameId][msg.sender], "Already minted in this game");
        require(msg.value == TICKET_PRICE, "Need exactly 0.1 MON");

        if (mintedCountPerGame[currentGameId] == 0) {
            gameStartTime[currentGameId] = block.timestamp;
            gameSeed[currentGameId]      = blockhash(block.number - 1);
            emit NewGame(currentGameId, block.timestamp);
        }

        require(block.timestamp < gameStartTime[currentGameId] + MINTING_DURATION, "Minting period ended");

        uint256 tokenId = _tokenIdCounter++;
        _safeMint(msg.sender, tokenId);

        hasMintedInGame[currentGameId][msg.sender] = true;
        mintedCountPerGame[currentGameId]++;

        uint8[10] memory numbers = _generateNumbers(tokenId);
        tokenToGameId[tokenId] = currentGameId;
        tokenToNumbers[tokenId] = numbers;
        playerTickets[msg.sender].push(tokenId);

        prizePool[currentGameId] += msg.value;
    }

    /*─────────────────  CLAIM  ─────────────────*/
    function claimWin(uint256 tokenId) external nonReentrant {
        uint256 gameId = currentGameId;
        require(winnerToken[gameId] == 0, "Game already claimed");

        uint256 start = gameStartTime[gameId];
        require(start != 0, "Game not started");

        uint256 mintEnd   = start + MINTING_DURATION;
        uint256 gameEnd   = mintEnd + 99 * DRAW_INTERVAL;        
        uint256 deadline  = gameEnd + PUBLIC_CLAIM_GRACE;

        if (block.timestamp >= deadline) {
            uint256 pool = prizePool[gameId];
            require(pool > 0, "Nothing to claim");

            prizePool[gameId]   = 0;
            winnerToken[gameId] = OPEN_CLAIM_WINNER;

            uint256 winnerPrize = (pool * 90) / 100;
            uint256 ownerPrize  = pool - winnerPrize;

            payable(msg.sender).transfer(winnerPrize);
            payable(owner()).transfer(ownerPrize);

            emit WinnerSelected(gameId, OPEN_CLAIM_WINNER);
            _prepareNewGame();
            return;
        }

        require(_exists(tokenId), "Token does not exist");
        require(tokenToGameId[tokenId] == gameId, "Token not in current game");
        require(_ownerOf(tokenId) == msg.sender, "Not token owner");

        uint256 draws = drawsSoFar(gameId);
        require(draws > 0, "Drawing not started yet");

        require(claimAttempts[tokenId] < MAX_CLAIM_ATTEMPTS, "Max claim attempts reached");
        claimAttempts[tokenId]++;

        uint8[] memory drawn = getDrawnNumbers(gameId, draws);
        uint8[10] memory playerNumbers = tokenToNumbers[tokenId];

        bool[100] memory present;
        for (uint256 i = 0; i < draws; i++) {
            present[drawn[i]] = true;
        }
        for (uint256 i = 0; i < 10; i++) {
            if (!present[playerNumbers[i]]) {
                emit AttemptFailed(gameId, tokenId);
                return;
            }
        }

        uint256 pool = prizePool[gameId];
        uint256 winnerPrize = (pool * 90) / 100;
        uint256 ownerPrize  = pool - winnerPrize;

        prizePool[gameId]   = 0;
        winnerToken[gameId] = tokenId;

        payable(msg.sender).transfer(winnerPrize);
        payable(owner()).transfer(ownerPrize);

        emit WinnerSelected(gameId, tokenId);
        _prepareNewGame();
    }


    function drawsSoFar(uint256 gameId) public view returns (uint256) {
        uint256 start = gameStartTime[gameId];
        if (start == 0) return 0;

        uint256 mintEnd = start + MINTING_DURATION;
        if (block.timestamp <= mintEnd) return 0;

        uint256 elapsed = (block.timestamp - mintEnd) / DRAW_INTERVAL + 1;
        if (elapsed > 99) elapsed = 99;
        return elapsed;
    }

    function _prepareNewGame() internal {
        currentGameId++;
    }

    /*──────────────  VIEW-хелпери  ─────────────*/
    function getUserTickets(address player) external view returns (uint256[] memory) {
        return playerTickets[player];
    }

    function getDrawnNumbers(uint256 gameId, uint256 N) public view returns (uint8[] memory) {
        require(N <= 99, "Too many draws");
        bytes32 seed = gameSeed[gameId];
        uint8[] memory numbers = new uint8[](99);
        for (uint256 i = 0; i < 99; i++) {
            numbers[i] = uint8(i + 1);
        }

        for (uint256 k = 0; k < N; k++) {
            uint256 j = k + uint256(keccak256(abi.encodePacked(seed, gameId, k))) % (99 - k);
            (numbers[k], numbers[j]) = (numbers[j], numbers[k]);
        }

        uint8[] memory drawn = new uint8[](N);
        for (uint256 i = 0; i < N; i++) {
            drawn[i] = numbers[i];
        }
        return drawn;
    }

    /*─────────────────  METADATA  ─────────────────*/
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        require(_exists(tokenId), "Token does not exist");

        uint256 gId = tokenToGameId[tokenId];
        bool finished = (winnerToken[gId] != 0);
        bool isWinner = finished && winnerToken[gId] == tokenId;

        string memory leafColor = finished ? (isWinner ? "#FFD700" : "#808080") : "#00B7EB"; // Блакитний за замовчуванням
        string memory bottomText = finished
            ? isWinner
                ? '<text x="50%" y="75%" font-size="18" fill="#FFD700" stroke="#FFFFFF" stroke-width="2" paint-order="stroke" text-anchor="middle">win!</text>'
                : '<text x="50%" y="75%" font-size="18" fill="#000000" stroke="#FFFFFF" stroke-width="2" paint-order="stroke" text-anchor="middle">lose!</text>'
            : "";

        string memory svg = string.concat(
            '<svg width="200" height="200" xmlns="http://www.w3.org/2000/svg">',
            '<path d="M100 30 C50 30 30 70 30 100 C30 130 50 170 100 170 C150 170 170 130 170 100 C170 70 150 30 100 30" fill="', leafColor, '"/>',
            '<text x="50%" y="50%" font-size="30" fill="#fff" text-anchor="middle" dy=".35em">#', gId.toString(), '</text>',
            bottomText,
            '</svg>'
        );

        string memory json = Base64.encode(
            abi.encodePacked(
                '{"name":"Lotonad Card #', tokenId.toString(),
                '","description":"Card for game #', gId.toString(),
                '","image":"data:image/svg+xml;base64,', Base64.encode(bytes(svg)), '"}'
            )
        );
        return string.concat("data:application/json;base64,", json);
    }

    function _generateNumbers(uint256 tokenId) internal view returns (uint8[10] memory) {
        uint8[10] memory numbers;
        uint256 randSeed = uint256(keccak256(abi.encodePacked(block.prevrandao, msg.sender, tokenId)));
        bool[100] memory used; 

        for (uint256 i = 0; i < 10; i++) {
            bool unique = false;
            while (!unique) {
                uint8 num = uint8((randSeed % 99) + 1); // 1 до 99
                randSeed = uint256(keccak256(abi.encodePacked(randSeed)));
                if (!used[num]) {
                    used[num] = true;
                    numbers[i] = num;
                    unique = true;
                }
            }
        }
        return numbers;
    }

    function _exists(uint256 id) internal view returns (bool) {
        return _ownerOf(id) != address(0);
    }

    function _fmt(uint256 n) internal pure returns (string memory) {
        if (n < 10) return string.concat("0", n.toString());
        return n.toString();
    }

    function getMintedCount(uint256 gameId) public view returns (uint256) {
        return mintedCountPerGame[gameId]; 
    }

    function getPrizePool(uint256 gameId) public view returns (uint256) {
        return prizePool[gameId];
    }

    function getPlayerTokenInGame(address player, uint256 gameId) public view returns (uint256) {
        for (uint256 i = 0; i < playerTickets[player].length; i++) {
            uint256 tokenId = playerTickets[player][i];
            if (tokenToGameId[tokenId] == gameId) {
                return tokenId;
            }
        }
        return type(uint256).max; 
    }

    function getTokenNumbers(uint256 tokenId) public view returns (uint8[10] memory) {
        require(_exists(tokenId), "Token does not exist");
        return tokenToNumbers[tokenId];
    }

    function getGameStatus(uint256 gameId) public view returns (bool isFinished, uint256 winnerTokenId) {
        isFinished = winnerToken[gameId] != 0;
        winnerTokenId = winnerToken[gameId];
    }

    function getGameSnapshot(address player)
        external
        view
        returns (
            uint256 gameId,
            uint256 startTime,
            uint256 mintEnd,
            uint256 gameEnd,
            uint256 draws,
            uint8 phase,              // 0 READY, 1 MINTING, 2 DRAWING, 3 FINISHED
            bool isFinished,
            uint256 winnerTokenId,
            uint256 playerTokenId,
            uint256 pool,
            uint256 mintedCount,
            uint8   claimTries
        )
    {
        gameId = currentGameId;

        startTime = gameStartTime[gameId];
        mintEnd   = startTime == 0 ? 0 : startTime + MINTING_DURATION;

        gameEnd   = mintEnd == 0 ? 0 : mintEnd + 99 * DRAW_INTERVAL;

        draws     = drawsSoFar(gameId);

        (isFinished, winnerTokenId) = getGameStatus(gameId);

        playerTokenId = getPlayerTokenInGame(player, gameId);

        pool        = prizePool[gameId];
        mintedCount = mintedCountPerGame[gameId];

        if (playerTokenId == type(uint256).max) {
            claimTries = 0;
        } else {
            uint256 raw = claimAttempts[playerTokenId];
            claimTries = raw > type(uint8).max ? type(uint8).max : uint8(raw);
        }

        if (isFinished) {
            phase = 3; // FINISHED
        } else if (startTime == 0) {
            phase = 0; // READY_TO_START (ще ніхто не мінтив)
        } else if (block.timestamp < mintEnd) {
            phase = 1; // MINTING
        } else {
            phase = 2; // DRAWING
        }
    }
}