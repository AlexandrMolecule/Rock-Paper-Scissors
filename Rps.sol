// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
import "@openzeppelin/contracts/access/Ownable.sol";

contract Rps is Ownable {
    receive() external payable {}

    fallback() external payable {}

    bool public paused;
    uint256 public lastGameId;
    uint256 public minBet;
    uint256 public timeoutInSeconds;

    constructor(uint256 _minBet, uint256 _timeoutInSeconds) payable {
        minBet = _minBet;
        timeoutInSeconds = _timeoutInSeconds;
    }

    // start game tracking storage

    mapping(uint256 => Game) public games;
    uint256[] public openGames;
    mapping(uint256 => uint256) public openGameIndex;
    mapping(address => uint256[]) public activeGamesOf;
    mapping(uint256 => uint256) public activeGameOfIndex;
    mapping(uint256 => uint256) public timingOutGames;

    // end game tracking storage

    enum Stage {
        Uninitialized, // 0
        Created, // 1
        Cancelled, // 2
        Ready, // 3
        Committed, // 4
        TimingOut, // 5
        TimedOut, // 6
        Tied, // 7
        WinnerDecided, // 8
        Paid // 9
    }

    enum Choice {
        None,
        Rock,
        Paper,
        Scissors
    }

    struct Game {
        address addressP1;
        address addressP2;
        address winner;
        uint256 bet;
        Choice choiceP1;
        Choice choiceP2;
        bytes32 choiceSecretP1;
        bytes32 choiceSecretP2;
        Stage stage;
    }

    // start events

    event Paused();

    event Unpaused();

    event StageChanged(uint256 indexed gameId, uint256 indexed stage);

    event GameCreated(uint256 indexed gameId, address indexed creator);

    event GameCancelled(uint256 indexed gameId, address indexed cancellor);

    event GameJoined(
        uint256 indexed gameId,
        address indexed creator,
        address indexed joiner
    );

    event ChoiceCommitted(uint256 indexed gameId, address committer);

    event ChoiceRevealed(uint256 indexed gameId, address revealer);

    event TimeoutStarted(
        uint256 indexed gameId,
        address indexed initiator,
        address indexed delayer
    );

    event TimedOut(
        uint256 indexed gameId,
        address indexed winner,
        address indexed loser
    );

    event Tied(
        uint256 indexed gameId,
        address indexed player1,
        address indexed player2
    );

    event WinnerDecided(
        uint256 indexed gameId,
        address indexed winner,
        address indexed loser
    );

    event BetSettled(
        uint256 indexed gameId,
        address indexed settler,
        uint256 winnings
    );

    event MinBetUpdated(uint256 oldMinBet, uint256 newMinBet);

    event TimeoutUpdated(uint256 oldTimeout, uint256 newTimeout);

    // end events

    // start modifiers

    modifier costs(uint _amount){
        require(msg.value >= _amount,
        'Not enough Ether provided!');
        _;
    }

    modifier whenNotPaused() {
        require(!paused);
        _;
    }

    modifier whenPaused() {
        require(paused);
        _;
    }

    modifier atStage(uint256 _gameId, Stage _stage) {
        require(games[_gameId].stage == _stage);

        _;
    }

    modifier atEitherStage(
        uint256 _gameId,
        Stage _stage,
        Stage _orStage
    ) {
        require(
            games[_gameId].stage == _stage || games[_gameId].stage == _orStage
        );

        _;
    }

    modifier timeoutAllowed(uint256 _gameId) {
        Game memory _game = games[_gameId];

        if (_game.stage == Stage.Ready) {
            require(
                _game.choiceSecretP1 == bytes32(0) ||
                    _game.choiceSecretP2 == bytes32(0)
            );
            require(
                _game.choiceSecretP1 != bytes32(0) ||
                    _game.choiceSecretP2 != bytes32(0)
            );
        }

        if (_game.stage == Stage.Committed) {
            require(
                _game.choiceP1 == Choice.None || _game.choiceP2 == Choice.None
            );
            require(
                _game.choiceP1 != Choice.None || _game.choiceP2 != Choice.None
            );
        }

        _;
    }

    modifier onlyGameParticipant(uint256 _gameId) {
        Game memory _game = games[_gameId];
        require(msg.sender == _game.addressP1 || msg.sender == _game.addressP2);

        _;
    }

    // end modifiers

    // start internal functions

    function removeActiveGameOf(address _player, uint256 _gameId) internal {
        require(activeGamesOf[_player].length > 0);
        uint256 _index = activeGameOfIndex[_gameId];

        activeGamesOf[_player][_index] = activeGamesOf[_player][
            activeGamesOf[_player].length - 1
        ];

        activeGamesOf[_player].pop();
    }

    function addActiveGameOf(address _player, uint256 _gameId) internal {
        activeGamesOf[_player].push(_gameId);
    }

    function enterStage(uint256 _gameId, Stage _newStage) internal {
        Stage _oldStage = games[_gameId].stage;

        // add gameId to openGames if newly created
        if (_oldStage == Stage.Uninitialized && _newStage == Stage.Created) {
            openGames.push(_gameId);
        }

        // remove gameId from openGames if leaving created status (someone joins/cancels)
        if (_oldStage == Stage.Created && _newStage != Stage.Created) {
            uint256 _operatingIndex = openGameIndex[_gameId];
            uint256 _replacingGameId = openGames[openGames.length - 1];
            openGames[_operatingIndex] = _replacingGameId;
            openGames.pop();
            openGameIndex[_replacingGameId] = _operatingIndex;
        }

        games[_gameId].stage = _newStage;

        emit StageChanged(_gameId, uint256(_newStage));
    }

    function computeWinner(uint256 _gameId) internal {
        Game storage _game = games[_gameId];
        Choice _c1 = _game.choiceP1;
        Choice _c2 = _game.choiceP2;
        address _a1 = _game.addressP1;
        address _a2 = _game.addressP2;

        if (_c1 == _c2) {
            enterStage(_gameId, Stage.Tied);

            emit Tied(_gameId, _a1, _a2);

            return;
        } else if (_c1 == Choice.Rock && _c2 == Choice.Paper) {
            _game.winner = _a2;
        } else if (_c1 == Choice.Rock && _c2 == Choice.Scissors) {
            _game.winner = _a1;
        } else if (_c1 == Choice.Paper && _c2 == Choice.Rock) {
            _game.winner = _a1;
        } else if (_c1 == Choice.Paper && _c2 == Choice.Scissors) {
            _game.winner = _a2;
        } else if (_c1 == Choice.Scissors && _c2 == Choice.Rock) {
            _game.winner = _a2;
        } else if (_c1 == Choice.Scissors && _c2 == Choice.Paper) {
            _game.winner = _a1;
        }

        enterStage(_gameId, Stage.WinnerDecided);

        address _loser = _game.winner == _a1 ? _a2 : _a1;

        emit WinnerDecided(_gameId, _game.winner, _loser);
    }

    function choiceSecretMatches(
        uint256 _gameId,
        Choice _choice,
        bytes memory _sig
    ) internal view returns (bool) {
        bytes32 _secret;
        Game memory _game = games[_gameId];

        if (msg.sender == _game.addressP1) {
            _secret = _game.choiceSecretP1;
        }

        if (msg.sender == _game.addressP2) {
            _secret = _game.choiceSecretP2;
        }

        return
            keccak256(abi.encodePacked(_gameId, uint256(_choice), _sig)) ==
            _secret;
    }

    // end internal  functions

    function allOpenGames() external view returns (uint256[] memory) {
        return openGames;
    }

    function openGamesLength() external view returns (uint256) {
        return openGames.length;
    }

    function allActiveGamesOf(address _address)
        external
        view
        returns (uint256[] memory)
    {
        return activeGamesOf[_address];
    }

    function allActiveGamesOfLength(address _address)
        external
        view
        returns (uint256)
    {
        return activeGamesOf[_address].length;
    }

    function gameHasTimedOut(uint256 _gameId) external view returns (bool) {
        return
            block.timestamp >= timingOutGames[_gameId] &&
            timingOutGames[_gameId] != 0;
    }

    // start game actions

    function createGame(uint256 _value) external payable whenNotPaused costs(_value) {
        require(_value >= minBet);
        lastGameId++;

        Game storage _newGame = games[lastGameId];
        _newGame.addressP1 = msg.sender;
        _newGame.bet = _value;

        enterStage(lastGameId, Stage.Created);

        addActiveGameOf(msg.sender, lastGameId);

        emit GameCreated(lastGameId, msg.sender);
    }

    function cancelGame(uint256 _gameId)
        external
        onlyGameParticipant(_gameId)
        atStage(_gameId, Stage.Created)
        whenNotPaused
    {
        enterStage(_gameId, Stage.Cancelled);
        Game memory _game = games[_gameId];
        require(address(this).balance >= _game.bet);
        payable(_game.addressP1).transfer(_game.bet);

        removeActiveGameOf(msg.sender, _gameId);

        emit GameCancelled(_gameId, msg.sender);
    }

    function joinGame(uint256 _gameId)
        external
        payable
        atStage(_gameId, Stage.Created)
        whenNotPaused
    {
        Game storage _game = games[_gameId];
         require(msg.value >= _game.bet, "Your bet is lower than game bet");

        require(_game.addressP1 != address(0));
        require(msg.sender != _game.addressP1);
        require(_game.addressP2 == address(0));

        _game.addressP2 = msg.sender;

        enterStage(_gameId, Stage.Ready);

        addActiveGameOf(msg.sender, _gameId);

        emit GameJoined(_gameId, _game.addressP1, msg.sender);
    }

    function commitChoice(uint256 _gameId, bytes32 _hash)
        external
        atEitherStage(_gameId, Stage.Ready, Stage.TimingOut)
        onlyGameParticipant(_gameId)
        whenNotPaused
    {
        Game storage _game = games[_gameId];
        if (msg.sender == _game.addressP1) {
            require(_game.choiceSecretP1 == bytes32(0));
            _game.choiceSecretP1 = _hash;
        } else {
            require(_game.choiceSecretP2 == bytes32(0));
            _game.choiceSecretP2 = _hash;
        }

        emit ChoiceCommitted(_gameId, msg.sender);

        if (
            _game.choiceSecretP1 != bytes32(0) &&
            _game.choiceSecretP2 != bytes32(0)
        ) {
            enterStage(_gameId, Stage.Committed);
        }
    }

    function revealChoice(
        uint256 _gameId,
        Choice _choice,
        bytes memory _sig
    )
        external
        atEitherStage(_gameId, Stage.Committed, Stage.TimingOut)
        onlyGameParticipant(_gameId)
        whenNotPaused
    {
        Game storage _game = games[_gameId];
        require(_game.choiceSecretP1 != bytes32(0));
        require(_game.choiceSecretP2 != bytes32(0));
        require(choiceSecretMatches(_gameId, _choice, _sig));

        if (msg.sender == _game.addressP1) {
            require(_game.choiceP1 == Choice.None);
            _game.choiceP1 = _choice;
        } else {
            require(_game.choiceP2 == Choice.None);
            _game.choiceP2 = _choice;
        }

        emit ChoiceRevealed(_gameId, msg.sender);

        if (_game.choiceP1 != Choice.None && _game.choiceP2 != Choice.None) {
            computeWinner(_gameId);
        }
    }

    // end game actions

    function removeActiveGame(uint256 _gameId) external whenNotPaused {
        removeActiveGameOf(msg.sender, _gameId);
    }

    function startGameTimeout(uint256 _gameId)
        external
        whenNotPaused
        atEitherStage(_gameId, Stage.Ready, Stage.Committed)
        onlyGameParticipant(_gameId)
        timeoutAllowed(_gameId)
    {
        timingOutGames[_gameId] = block.timestamp + timeoutInSeconds;

        enterStage(_gameId, Stage.TimingOut);

        Game memory _game = games[_gameId];
        address _delayer = msg.sender == _game.addressP1
            ? _game.addressP2
            : _game.addressP1;

        emit TimeoutStarted(_gameId, msg.sender, _delayer);
    }

    function timeoutGame(uint256 _gameId)
        external
        whenNotPaused
        atStage(_gameId, Stage.TimingOut)
        onlyGameParticipant(_gameId)
        timeoutAllowed(_gameId)
    {
        require(block.timestamp >= timingOutGames[_gameId]);
        Game storage _game = games[_gameId];
        address _loser;

        if (
            _game.choiceSecretP1 == bytes32(0) ||
            _game.choiceSecretP2 == bytes32(0)
        ) {
            _game.winner = _game.choiceSecretP1 == bytes32(0)
                ? _game.addressP2
                : _game.addressP1;

            _loser = _game.winner == _game.addressP1
                ? _game.addressP2
                : _game.addressP1;
        } else if (
            _game.choiceP1 == Choice.None || _game.choiceP2 == Choice.None
        ) {
            _game.winner = _game.choiceP1 == Choice.None
                ? _game.addressP2
                : _game.addressP1;

            _loser = _game.winner == _game.addressP1
                ? _game.addressP2
                : _game.addressP1;
        }

        enterStage(_gameId, Stage.TimedOut);

        emit TimedOut(_gameId, _game.winner, _loser);
    }

    function settleWinner(
        uint256 _gameId,
        Game memory _game,
        uint256 _bet1,
        uint256 _bet2
    ) internal {
        address _loser = _game.winner == _game.addressP1
            ? _game.addressP2
            : _game.addressP1;
        uint256 _deAllocationAmount = _game.winner == _game.addressP1
            ? _bet1
            : _bet2;
        uint256 _transferAmount = _loser == _game.addressP1 ? _bet1 : _bet2;
        payable(_game.winner).transfer(_game.bet*2);
        emit BetSettled(
            _gameId,
            _game.winner,
            _deAllocationAmount + _transferAmount
        );
    }

    function settleTied(
        uint256 _gameId,
        Game memory _game,
        uint256 _bet1,
        uint256 _bet2
    ) internal {
        payable(_game.addressP1).transfer(_game.bet);
        payable(_game.addressP2).transfer(_game.bet);

        emit BetSettled(_gameId, _game.addressP1, _bet1);

        emit BetSettled(_gameId, _game.addressP2, _bet2);
    }

    function settleBet(uint256 _gameId) external whenNotPaused {
        Game memory _game = games[_gameId];
        // ensure that Stage is any of: TimedOut, Tied, WinnerDecided
        require(uint256(_game.stage) >= 6 && uint256(_game.stage) <= 8);

        if (_game.stage == Stage.WinnerDecided) {
            settleWinner(_gameId, _game, _game.bet, _game.bet);
        } else if (_game.stage == Stage.Tied) {
            settleTied(_gameId, _game, _game.bet, _game.bet);
        } else if (_game.stage == Stage.TimedOut) {
            settleWinner(_gameId, _game, _game.bet, _game.bet);
        }

        enterStage(_gameId, Stage.Paid);
    }

    // end game management functions

    // start owner only functions

    function pause() external onlyOwner whenNotPaused {
        paused = true;
        emit Paused();
    }

    function unpause() external onlyOwner whenPaused {
        paused = false;
        emit Unpaused();
    }

    function updateMinBet(uint256 _newMinBet) external onlyOwner {
        uint256 _oldMinBet = minBet;
        minBet = _newMinBet;

        emit MinBetUpdated(_oldMinBet, _newMinBet);
    }

    function updateTimeout(uint256 _newTimeoutInSeconds) external onlyOwner {
        require(_newTimeoutInSeconds >= 60);

        uint256 _oldTimeoutInSeconds = timeoutInSeconds;
        timeoutInSeconds = _newTimeoutInSeconds;

        emit TimeoutUpdated(_oldTimeoutInSeconds, _newTimeoutInSeconds);
    }
    // end owner only functions
}
