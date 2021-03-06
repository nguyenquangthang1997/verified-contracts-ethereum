pragma solidity 0.5.16;


/// @title Spawn
/// @author 0age (@0age) for Numerai Inc
/// @dev Security contact: security@numer.ai
/// @dev Version: 1.3.0
/// @notice This contract provides creation code that is used by Spawner in order
/// to initialize and deploy eip-1167 minimal proxies for a given logic contract.
contract Spawn {
    constructor(
        address logicContract,
        bytes memory initializationCalldata
    ) public payable {
        // delegatecall into the logic contract to perform initialization.
        (bool ok,) = logicContract.delegatecall(initializationCalldata);
        if (!ok) {
            // pass along failure message from delegatecall and revert.
            assembly {
                returndatacopy(0, 0, returndatasize)
                revert(0, returndatasize)
            }
        }

        // place eip-1167 runtime code in memory.
        bytes memory runtimeCode = abi.encodePacked(
            bytes10(0x363d3d373d3d3d363d73),
            logicContract,
            bytes15(0x5af43d82803e903d91602b57fd5bf3)
        );

        // return eip-1167 code to write it to spawned contract runtime.
        assembly {
            return (add(0x20, runtimeCode), 45) // eip-1167 runtime code, length
        }
    }
}

/// @title Spawner
/// @author 0age (@0age) and Stephane Gosselin (@thegostep) for Numerai Inc
/// @dev Security contact: security@numer.ai
/// @dev Version: 1.3.0
/// @notice This contract spawns and initializes eip-1167 minimal proxies that
/// point to existing logic contracts. The logic contracts need to have an
/// initializer function that should only callable when no contract exists at
/// their current address (i.e. it is being `DELEGATECALL`ed from a constructor).
contract Spawner {

    /// @notice Internal function for spawning an eip-1167 minimal proxy using `CREATE2`.
    /// @param creator address The address of the account creating the proxy.
    /// @param logicContract address The address of the logic contract.
    /// @param initializationCalldata bytes The calldata that will be supplied to
    /// the `DELEGATECALL` from the spawned contract to the logic contract during
    /// contract creation.
    /// @return The address of the newly-spawned contract.
    function _spawn(
        address creator,
        address logicContract,
        bytes memory initializationCalldata
    ) internal returns (address spawnedContract) {

        // get instance code and hash

        bytes memory initCode;
        bytes32 initCodeHash;
        (initCode, initCodeHash) = _getInitCodeAndHash(logicContract, initializationCalldata);

        // get valid create2 target

        (address target, bytes32 safeSalt) = _getNextNonceTargetWithInitCodeHash(creator, initCodeHash);

        // spawn create2 instance and validate

        return _executeSpawnCreate2(initCode, safeSalt, target);
    }

    /// @notice Internal function for spawning an eip-1167 minimal proxy using `CREATE2`.
    /// @param creator address The address of the account creating the proxy.
    /// @param logicContract address The address of the logic contract.
    /// @param initializationCalldata bytes The calldata that will be supplied to
    /// the `DELEGATECALL` from the spawned contract to the logic contract during
    /// contract creation.
    /// @param salt bytes32 A user defined salt.
    /// @return The address of the newly-spawned contract.
    function _spawnSalty(
        address creator,
        address logicContract,
        bytes memory initializationCalldata,
        bytes32 salt
    ) internal returns (address spawnedContract) {

        // get instance code and hash

        bytes memory initCode;
        bytes32 initCodeHash;
        (initCode, initCodeHash) = _getInitCodeAndHash(logicContract, initializationCalldata);

        // get valid create2 target

        (address target, bytes32 safeSalt, bool validity) = _getSaltyTargetWithInitCodeHash(creator, initCodeHash, salt);
        require(validity, "contract already deployed with supplied salt");

        // spawn create2 instance and validate

        return _executeSpawnCreate2(initCode, safeSalt, target);
    }

    /// @notice Private function for spawning an eip-1167 minimal proxy using `CREATE2`.
    /// Reverts with appropriate error string if deployment is unsuccessful.
    /// @param initCode bytes The spawner code and initialization calldata.
    /// @param safeSalt bytes32 A valid salt hashed with creator address.
    /// @param target address The expected address of the proxy.
    /// @return The address of the newly-spawned contract.
    function _executeSpawnCreate2(bytes memory initCode, bytes32 safeSalt, address target) private returns (address spawnedContract) {
        assembly {
            let encoded_data := add(0x20, initCode) // load initialization code.
            let encoded_size := mload(initCode)     // load the init code's length.
            spawnedContract := create2(// call `CREATE2` w/ 4 arguments.
            callvalue, // forward any supplied endowment.
            encoded_data, // pass in initialization code.
            encoded_size, // pass in init code's length.
            safeSalt                              // pass in the salt value.
            )

        // pass along failure message from failed contract deployment and revert.
            if iszero(spawnedContract) {
                returndatacopy(0, 0, returndatasize)
                revert(0, returndatasize)
            }
        }

        // validate spawned instance matches target
        require(spawnedContract == target, "attempted deployment to unexpected address");

        // explicit return
        return spawnedContract;
    }

    /// @notice Internal view function for finding the expected address of the standard
    /// eip-1167 minimal proxy created using `CREATE2` with a given logic contract,
    /// salt, and initialization calldata payload.
    /// @param creator address The address of the account creating the proxy.
    /// @param logicContract address The address of the logic contract.
    /// @param initializationCalldata bytes The calldata that will be supplied to
    /// the `DELEGATECALL` from the spawned contract to the logic contract during
    /// contract creation.
    /// @param salt bytes32 A user defined salt.
    /// @return target address The address of the newly-spawned contract.
    /// @return validity bool True if the `target` is available.
    function _getSaltyTarget(
        address creator,
        address logicContract,
        bytes memory initializationCalldata,
        bytes32 salt
    ) internal view returns (address target, bool validity) {

        // get initialization code

        bytes32 initCodeHash;
        (, initCodeHash) = _getInitCodeAndHash(logicContract, initializationCalldata);

        // get valid target

        (target, , validity) = _getSaltyTargetWithInitCodeHash(creator, initCodeHash, salt);

        // explicit return
        return (target, validity);
    }

    /// @notice Internal view function for finding the expected address of the standard
    /// eip-1167 minimal proxy created using `CREATE2` with a given initCodeHash, and salt.
    /// @param creator address The address of the account creating the proxy.
    /// @param initCodeHash bytes32 The hash of initCode.
    /// @param salt bytes32 A user defined salt.
    /// @return target address The address of the newly-spawned contract.
    /// @return safeSalt bytes32 A safe salt. Must include the msg.sender address for front-running protection.
    /// @return validity bool True if the `target` is available.
    function _getSaltyTargetWithInitCodeHash(
        address creator,
        bytes32 initCodeHash,
        bytes32 salt
    ) private view returns (address target, bytes32 safeSalt, bool validity) {
        // get safeSalt from input
        safeSalt = keccak256(abi.encodePacked(creator, salt));

        // get expected target
        target = _computeTargetWithCodeHash(initCodeHash, safeSalt);

        // get target validity
        validity = _getTargetValidity(target);

        // explicit return
        return (target, safeSalt, validity);
    }

    /// @notice Internal view function for finding the expected address of the standard
    /// eip-1167 minimal proxy created using `CREATE2` with a given logic contract,
    /// nonce, and initialization calldata payload.
    /// @param creator address The address of the account creating the proxy.
    /// @param logicContract address The address of the logic contract.
    /// @param initializationCalldata bytes The calldata that will be supplied to
    /// the `DELEGATECALL` from the spawned contract to the logic contract during
    /// contract creation.
    /// @return target address The address of the newly-spawned contract.
    function _getNextNonceTarget(
        address creator,
        address logicContract,
        bytes memory initializationCalldata
    ) internal view returns (address target) {

        // get initialization code

        bytes32 initCodeHash;
        (, initCodeHash) = _getInitCodeAndHash(logicContract, initializationCalldata);

        // get valid target

        (target,) = _getNextNonceTargetWithInitCodeHash(creator, initCodeHash);

        // explicit return
        return target;
    }

    /// @notice Internal view function for finding the expected address of the standard
    /// eip-1167 minimal proxy created using `CREATE2` with a given initCodeHash, and nonce.
    /// @param creator address The address of the account creating the proxy.
    /// @param initCodeHash bytes32 The hash of initCode.
    /// @return target address The address of the newly-spawned contract.
    /// @return safeSalt bytes32 A safe salt. Must include the msg.sender address for front-running protection.
    function _getNextNonceTargetWithInitCodeHash(
        address creator,
        bytes32 initCodeHash
    ) private view returns (address target, bytes32 safeSalt) {
        // set the initial nonce to be provided when constructing the salt.
        uint256 nonce = 0;

        while (true) {
            // get safeSalt from nonce
            safeSalt = keccak256(abi.encodePacked(creator, nonce));

            // get expected target
            target = _computeTargetWithCodeHash(initCodeHash, safeSalt);

            // validate no contract already deployed to the target address.
            // exit the loop if no contract is deployed to the target address.
            // otherwise, increment the nonce and derive a new salt.
            if (_getTargetValidity(target))
                break;
            else
                nonce++;
        }

        // explicit return
        return (target, safeSalt);
    }

    /// @notice Private pure function for obtaining the initCode and the initCodeHash of `logicContract` and `initializationCalldata`.
    /// @param logicContract address The address of the logic contract.
    /// @param initializationCalldata bytes The calldata that will be supplied to
    /// the `DELEGATECALL` from the spawned contract to the logic contract during
    /// contract creation.
    /// @return initCode bytes The spawner code and initialization calldata.
    /// @return initCodeHash bytes32 The hash of initCode.
    function _getInitCodeAndHash(
        address logicContract,
        bytes memory initializationCalldata
    ) private pure returns (bytes memory initCode, bytes32 initCodeHash) {
        // place creation code and constructor args of contract to spawn in memory.
        initCode = abi.encodePacked(
            type(Spawn).creationCode,
            abi.encode(logicContract, initializationCalldata)
        );

        // get the keccak256 hash of the init code for address derivation.
        initCodeHash = keccak256(initCode);

        // explicit return
        return (initCode, initCodeHash);
    }

    /// @notice Private view function for finding the expected address of the standard
    /// eip-1167 minimal proxy created using `CREATE2` with a given logic contract,
    /// salt, and initialization calldata payload.
    /// @param initCodeHash bytes32 The hash of initCode.
    /// @param safeSalt bytes32 A safe salt. Must include the msg.sender address for front-running protection.
    /// @return The address of the proxy contract with the given parameters.
    function _computeTargetWithCodeHash(
        bytes32 initCodeHash,
        bytes32 safeSalt
    ) private view returns (address target) {
        return address(// derive the target deployment address.
            uint160(// downcast to match the address type.
                uint256(// cast to uint to truncate upper digits.
                    keccak256(// compute CREATE2 hash using 4 inputs.
                        abi.encodePacked(// pack all inputs to the hash together.
                            bytes1(0xff), // pass in the control character.
                            address(this), // pass in the address of this contract.
                            safeSalt, // pass in the safeSalt from above.
                            initCodeHash       // pass in hash of contract creation code.
                        )
                    )
                )
            )
        );
    }

    /// @notice Private view function to validate if the `target` address is an available deployment address.
    /// @param target address The address to validate.
    /// @return validity bool True if the `target` is available.
    function _getTargetValidity(address target) private view returns (bool validity) {
        // validate no contract already deployed to the target address.
        uint256 codeSize;
        assembly {codeSize := extcodesize(target)}
        return codeSize == 0;
    }
}



/// @title iRegistry
/// @author Stephane Gosselin (@thegostep) for Numerai Inc
/// @dev Security contact: security@numer.ai
/// @dev Version: 1.3.0
interface iRegistry {

    enum FactoryStatus {Unregistered, Registered, Retired}

    event FactoryAdded(address owner, address factory, uint256 factoryID, bytes extraData);
    event FactoryRetired(address owner, address factory, uint256 factoryID);
    event InstanceRegistered(address instance, uint256 instanceIndex, address indexed creator, address indexed factory, uint256 indexed factoryID);

    // factory state functions

    function addFactory(address factory, bytes calldata extraData) external;

    function retireFactory(address factory) external;

    // factory view functions

    function getFactoryCount() external view returns (uint256 count);

    function getFactoryStatus(address factory) external view returns (FactoryStatus status);

    function getFactoryID(address factory) external view returns (uint16 factoryID);

    function getFactoryData(address factory) external view returns (bytes memory extraData);

    function getFactoryAddress(uint16 factoryID) external view returns (address factory);

    function getFactory(address factory) external view returns (FactoryStatus state, uint16 factoryID, bytes memory extraData);

    function getFactories() external view returns (address[] memory factories);

    function getPaginatedFactories(uint256 startIndex, uint256 endIndex) external view returns (address[] memory factories);

    // instance state functions

    function register(address instance, address creator, uint80 extraData) external;

    // instance view functions

    function getInstanceType() external view returns (bytes4 instanceType);

    function getInstanceCount() external view returns (uint256 count);

    function getInstance(uint256 index) external view returns (address instance);

    function getInstances() external view returns (address[] memory instances);

    function getPaginatedInstances(uint256 startIndex, uint256 endIndex) external view returns (address[] memory instances);
}


/// @title iFactory
/// @author Stephane Gosselin (@thegostep) for Numerai Inc
/// @dev Security contact: security@numer.ai
/// @dev Version: 1.3.0
interface iFactory {

    event InstanceCreated(address indexed instance, address indexed creator, bytes callData);

    function create(bytes calldata callData) external returns (address instance);

    function createSalty(bytes calldata callData, bytes32 salt) external returns (address instance);

    function getInitSelector() external view returns (bytes4 initSelector);

    function getInstanceRegistry() external view returns (address instanceRegistry);

    function getTemplate() external view returns (address template);

    function getSaltyInstance(address creator, bytes calldata callData, bytes32 salt) external view returns (address instance, bool validity);

    function getNextNonceInstance(address creator, bytes calldata callData) external view returns (address instance);

    function getInstanceCreator(address instance) external view returns (address creator);

    function getInstanceType() external view returns (bytes4 instanceType);

    function getInstanceCount() external view returns (uint256 count);

    function getInstance(uint256 index) external view returns (address instance);

    function getInstances() external view returns (address[] memory instances);

    function getPaginatedInstances(uint256 startIndex, uint256 endIndex) external view returns (address[] memory instances);
}



/// @title EventMetadata
/// @author Stephane Gosselin (@thegostep) for Numerai Inc
/// @dev Security contact: security@numer.ai
/// @dev Version: 1.3.0
/// @notice This module emits metadata blob as an event.
contract EventMetadata {

    event MetadataSet(bytes metadata);

    // state functions

    /// @notice Emit a metadata blob.
    /// @param metadata data blob of any format.
    function _setMetadata(bytes memory metadata) internal {
        emit MetadataSet(metadata);
    }
}



/// @title Operated
/// @author Stephane Gosselin (@thegostep) for Numerai Inc
/// @dev Security contact: security@numer.ai
/// @dev Version: 1.3.0
contract Operated {

    address private _operator;

    event OperatorUpdated(address operator);

    // state functions

    function _setOperator(address operator) internal {

        // can only be called when operator is null
        require(_operator == address(0), "operator already set");

        // cannot set to address 0
        require(operator != address(0), "cannot set operator to address 0");

        // set operator in storage
        _operator = operator;

        // emit event
        emit OperatorUpdated(operator);
    }

    function _transferOperator(address operator) internal {

        // requires existing operator
        require(_operator != address(0), "only when operator set");

        // cannot set to address 0
        require(operator != address(0), "cannot set operator to address 0");

        // set operator in storage
        _operator = operator;

        // emit event
        emit OperatorUpdated(operator);
    }

    function _renounceOperator() internal {

        // requires existing operator
        require(_operator != address(0), "only when operator set");

        // set operator in storage
        _operator = address(0);

        // emit event
        emit OperatorUpdated(address(0));
    }

    // view functions

    function getOperator() public view returns (address operator) {
        return _operator;
    }

    function isOperator(address caller) internal view returns (bool ok) {
        return caller == _operator;
    }

}



/// @title Template
/// @author Stephane Gosselin (@thegostep) for Numerai Inc
/// @dev Security contact: security@numer.ai
/// @dev Version: 1.3.0
/// @notice This module is imported by all template contracts to implement core functionality associated with the factories.
contract Template {

    address private _factory;

    // modifiers

    /// @notice Modifier which only allows to be `DELEGATECALL`ed from within a constructor on initialization of the contract.
    modifier initializeTemplate() {
        // set factory
        _factory = msg.sender;

        // only allow function to be `DELEGATECALL`ed from within a constructor.
        uint32 codeSize;
        assembly {codeSize := extcodesize(
        address)}
        require(codeSize == 0, "must be called within contract constructor");
        _;
    }

    // view functions

    /// @notice Get the address that created this clone.
    ///         Note, this cannot be trusted because it is possible to frontrun the create function and become the creator.
    /// @return creator address that created this clone.
    function getCreator() public view returns (address creator) {
        // iFactory(...) would revert if _factory address is not actually a factory contract
        return iFactory(_factory).getInstanceCreator(address(this));
    }

    /// @notice Validate if address matches the stored creator.
    /// @param caller address to validate.
    /// @return validity bool true if matching address.
    function isCreator(address caller) internal view returns (bool validity) {
        return (caller == getCreator());
    }

    /// @notice Get the address of the factory for this clone.
    /// @return factory address of the factory.
    function getFactory() public view returns (address factory) {
        return _factory;
    }

}



/// @title ProofHashes
/// @author Stephane Gosselin (@thegostep) for Numerai Inc
/// @dev Security contact: security@numer.ai
/// @dev Version: 1.3.0
contract ProofHashes {

    event HashSubmitted(bytes32 hash);

    // state functions

    function _submitHash(bytes32 hash) internal {
        // emit event
        emit HashSubmitted(hash);
    }

}


/**
 * @dev Interface of the ERC20 standard as defined in the EIP. Does not include
 * the optional functions; to access them see {ERC20Detailed}.
 */
interface IERC20 {
    /**
     * @dev Returns the amount of tokens in existence.
     */
    function totalSupply() external view returns (uint256);

    /**
     * @dev Returns the amount of tokens owned by `account`.
     */
    function balanceOf(address account) external view returns (uint256);

    /**
     * @dev Moves `amount` tokens from the caller's account to `recipient`.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transfer(address recipient, uint256 amount) external returns (bool);

    /**
     * @dev Returns the remaining number of tokens that `spender` will be
     * allowed to spend on behalf of `owner` through {transferFrom}. This is
     * zero by default.
     *
     * This value changes when {approve} or {transferFrom} are called.
     */
    function allowance(address owner, address spender) external view returns (uint256);

    /**
     * @dev Sets `amount` as the allowance of `spender` over the caller's tokens.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * IMPORTANT: Beware that changing an allowance with this method brings the risk
     * that someone may use both the old and the new allowance by unfortunate
     * transaction ordering. One possible solution to mitigate this race
     * condition is to first reduce the spender's allowance to 0 and set the
     * desired value afterwards:
     * https://github.com/ethereum/EIPs/issues/20#issuecomment-263524729
     *
     * Emits an {Approval} event.
     */
    function approve(address spender, uint256 amount) external returns (bool);

    /**
     * @dev Moves `amount` tokens from `sender` to `recipient` using the
     * allowance mechanism. `amount` is then deducted from the caller's
     * allowance.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);

    /**
     * @dev Emitted when `value` tokens are moved from one account (`from`) to
     * another (`to`).
     *
     * Note that `value` may be zero.
     */
    event Transfer(address indexed from, address indexed to, uint256 value);

    /**
     * @dev Emitted when the allowance of a `spender` for an `owner` is set by
     * a call to {approve}. `value` is the new allowance.
     */
    event Approval(address indexed owner, address indexed spender, uint256 value);
}


/**
 * @dev Wrappers over Solidity's arithmetic operations with added overflow
 * checks.
 *
 * Arithmetic operations in Solidity wrap on overflow. This can easily result
 * in bugs, because programmers usually assume that an overflow raises an
 * error, which is the standard behavior in high level programming languages.
 * `SafeMath` restores this intuition by reverting the transaction when an
 * operation overflows.
 *
 * Using this library instead of the unchecked operations eliminates an entire
 * class of bugs, so it's recommended to use it always.
 */
library SafeMath {
    /**
     * @dev Returns the addition of two unsigned integers, reverting on
     * overflow.
     *
     * Counterpart to Solidity's `+` operator.
     *
     * Requirements:
     * - Addition cannot overflow.
     */
    function add(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 c = a + b;
        require(c >= a, "SafeMath: addition overflow");

        return c;
    }

    /**
     * @dev Returns the subtraction of two unsigned integers, reverting on
     * overflow (when the result is negative).
     *
     * Counterpart to Solidity's `-` operator.
     *
     * Requirements:
     * - Subtraction cannot overflow.
     */
    function sub(uint256 a, uint256 b) internal pure returns (uint256) {
        return sub(a, b, "SafeMath: subtraction overflow");
    }

    /**
     * @dev Returns the subtraction of two unsigned integers, reverting with custom message on
     * overflow (when the result is negative).
     *
     * Counterpart to Solidity's `-` operator.
     *
     * Requirements:
     * - Subtraction cannot overflow.
     *
     * _Available since v2.4.0._
     */
    function sub(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        require(b <= a, errorMessage);
        uint256 c = a - b;

        return c;
    }

    /**
     * @dev Returns the multiplication of two unsigned integers, reverting on
     * overflow.
     *
     * Counterpart to Solidity's `*` operator.
     *
     * Requirements:
     * - Multiplication cannot overflow.
     */
    function mul(uint256 a, uint256 b) internal pure returns (uint256) {
        // Gas optimization: this is cheaper than requiring 'a' not being zero, but the
        // benefit is lost if 'b' is also tested.
        // See: https://github.com/OpenZeppelin/openzeppelin-contracts/pull/522
        if (a == 0) {
            return 0;
        }

        uint256 c = a * b;
        require(c / a == b, "SafeMath: multiplication overflow");

        return c;
    }

    /**
     * @dev Returns the integer division of two unsigned integers. Reverts on
     * division by zero. The result is rounded towards zero.
     *
     * Counterpart to Solidity's `/` operator. Note: this function uses a
     * `revert` opcode (which leaves remaining gas untouched) while Solidity
     * uses an invalid opcode to revert (consuming all remaining gas).
     *
     * Requirements:
     * - The divisor cannot be zero.
     */
    function div(uint256 a, uint256 b) internal pure returns (uint256) {
        return div(a, b, "SafeMath: division by zero");
    }

    /**
     * @dev Returns the integer division of two unsigned integers. Reverts with custom message on
     * division by zero. The result is rounded towards zero.
     *
     * Counterpart to Solidity's `/` operator. Note: this function uses a
     * `revert` opcode (which leaves remaining gas untouched) while Solidity
     * uses an invalid opcode to revert (consuming all remaining gas).
     *
     * Requirements:
     * - The divisor cannot be zero.
     *
     * _Available since v2.4.0._
     */
    function div(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        // Solidity only automatically asserts when dividing by 0
        require(b > 0, errorMessage);
        uint256 c = a / b;
        // assert(a == b * c + a % b); // There is no case in which this doesn't hold

        return c;
    }

    /**
     * @dev Returns the remainder of dividing two unsigned integers. (unsigned integer modulo),
     * Reverts when dividing by zero.
     *
     * Counterpart to Solidity's `%` operator. This function uses a `revert`
     * opcode (which leaves remaining gas untouched) while Solidity uses an
     * invalid opcode to revert (consuming all remaining gas).
     *
     * Requirements:
     * - The divisor cannot be zero.
     */
    function mod(uint256 a, uint256 b) internal pure returns (uint256) {
        return mod(a, b, "SafeMath: modulo by zero");
    }

    /**
     * @dev Returns the remainder of dividing two unsigned integers. (unsigned integer modulo),
     * Reverts with custom message when dividing by zero.
     *
     * Counterpart to Solidity's `%` operator. This function uses a `revert`
     * opcode (which leaves remaining gas untouched) while Solidity uses an
     * invalid opcode to revert (consuming all remaining gas).
     *
     * Requirements:
     * - The divisor cannot be zero.
     *
     * _Available since v2.4.0._
     */
    function mod(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        require(b != 0, errorMessage);
        return a % b;
    }
}


contract UniswapExchangeInterface {
    // Address of ERC20 token sold on this exchange
    function tokenAddress() external view returns (address token);
    // Address of Uniswap Factory
    function factoryAddress() external view returns (address factory);
    // Provide Liquidity
    function addLiquidity(uint256 min_liquidity, uint256 max_tokens, uint256 deadline) external payable returns (uint256);

    function removeLiquidity(uint256 amount, uint256 min_eth, uint256 min_tokens, uint256 deadline) external returns (uint256, uint256);
    // Get Prices
    function getEthToTokenInputPrice(uint256 eth_sold) external view returns (uint256 tokens_bought);

    function getEthToTokenOutputPrice(uint256 tokens_bought) external view returns (uint256 eth_sold);

    function getTokenToEthInputPrice(uint256 tokens_sold) external view returns (uint256 eth_bought);

    function getTokenToEthOutputPrice(uint256 eth_bought) external view returns (uint256 tokens_sold);
    // Trade ETH to ERC20
    function ethToTokenSwapInput(uint256 min_tokens, uint256 deadline) external payable returns (uint256 tokens_bought);

    function ethToTokenTransferInput(uint256 min_tokens, uint256 deadline, address recipient) external payable returns (uint256 tokens_bought);

    function ethToTokenSwapOutput(uint256 tokens_bought, uint256 deadline) external payable returns (uint256 eth_sold);

    function ethToTokenTransferOutput(uint256 tokens_bought, uint256 deadline, address recipient) external payable returns (uint256 eth_sold);
    // Trade ERC20 to ETH
    function tokenToEthSwapInput(uint256 tokens_sold, uint256 min_eth, uint256 deadline) external returns (uint256 eth_bought);

    function tokenToEthTransferInput(uint256 tokens_sold, uint256 min_eth, uint256 deadline, address recipient) external returns (uint256 eth_bought);

    function tokenToEthSwapOutput(uint256 eth_bought, uint256 max_tokens, uint256 deadline) external returns (uint256 tokens_sold);

    function tokenToEthTransferOutput(uint256 eth_bought, uint256 max_tokens, uint256 deadline, address recipient) external returns (uint256 tokens_sold);
    // Trade ERC20 to ERC20
    function tokenToTokenSwapInput(uint256 tokens_sold, uint256 min_tokens_bought, uint256 min_eth_bought, uint256 deadline, address token_addr) external returns (uint256 tokens_bought);

    function tokenToTokenTransferInput(uint256 tokens_sold, uint256 min_tokens_bought, uint256 min_eth_bought, uint256 deadline, address recipient, address token_addr) external returns (uint256 tokens_bought);

    function tokenToTokenSwapOutput(uint256 tokens_bought, uint256 max_tokens_sold, uint256 max_eth_sold, uint256 deadline, address token_addr) external returns (uint256 tokens_sold);

    function tokenToTokenTransferOutput(uint256 tokens_bought, uint256 max_tokens_sold, uint256 max_eth_sold, uint256 deadline, address recipient, address token_addr) external returns (uint256 tokens_sold);
    // Trade ERC20 to Custom Pool
    function tokenToExchangeSwapInput(uint256 tokens_sold, uint256 min_tokens_bought, uint256 min_eth_bought, uint256 deadline, address exchange_addr) external returns (uint256 tokens_bought);

    function tokenToExchangeTransferInput(uint256 tokens_sold, uint256 min_tokens_bought, uint256 min_eth_bought, uint256 deadline, address recipient, address exchange_addr) external returns (uint256 tokens_bought);

    function tokenToExchangeSwapOutput(uint256 tokens_bought, uint256 max_tokens_sold, uint256 max_eth_sold, uint256 deadline, address exchange_addr) external returns (uint256 tokens_sold);

    function tokenToExchangeTransferOutput(uint256 tokens_bought, uint256 max_tokens_sold, uint256 max_eth_sold, uint256 deadline, address recipient, address exchange_addr) external returns (uint256 tokens_sold);
    // ERC20 comaptibility for liquidity tokens
    bytes32 public name;
    bytes32 public symbol;
    uint256 public decimals;

    function transfer(address _to, uint256 _value) external returns (bool);

    function transferFrom(address _from, address _to, uint256 value) external returns (bool);

    function approve(address _spender, uint256 _value) external returns (bool);

    function allowance(address _owner, address _spender) external view returns (uint256);

    function balanceOf(address _owner) external view returns (uint256);

    function totalSupply() external view returns (uint256);
    // Never use
    function setup(address token_addr) external;
}


/// @title iNMR
/// @author Stephane Gosselin (@thegostep) for Numerai Inc
/// @dev Security contact: security@numer.ai
/// @dev Version: 1.3.0
contract iNMR {

    // ERC20
    function totalSupply() external returns (uint256);

    function balanceOf(address _owner) external returns (uint256);

    function allowance(address _owner, address _spender) external returns (uint256);

    function transfer(address _to, uint256 _value) external returns (bool ok);

    function transferFrom(address _from, address _to, uint256 _value) external returns (bool ok);

    function approve(address _spender, uint256 _value) external returns (bool ok);

    function changeApproval(address _spender, uint256 _oldValue, uint256 _newValue) external returns (bool ok);

    /// @dev Behavior has changed to match OpenZeppelin's `ERC20Burnable.burn(uint256 amount)`
    /// @dev Destoys `amount` tokens from `msg.sender`, reducing the total supply.
    ///
    /// Emits a `Transfer` event with `to` set to the zero address.
    /// Requirements:
    /// - `account` must have at least `amount` tokens.
    function mint(uint256 _value) external returns (bool ok);

    /// @dev Behavior has changed to match OpenZeppelin's `ERC20Burnable.burnFrom(address account, uint256 amount)`
    /// @dev Destoys `amount` tokens from `account`.`amount` is then deducted
    /// from the caller's allowance.
    ///
    /// Emits an `Approval` event indicating the updated allowance.
    /// Emits a `Transfer` event with `to` set to the zero address.
    ///
    /// Requirements:
    /// - `account` must have at least `amount` tokens.
    /// - `account` must have approved `msg.sender` with allowance of at least `amount` tokens.
    function numeraiTransfer(address _to, uint256 _value) external returns (bool ok);
}





/// @title Factory
/// @author Stephane Gosselin (@thegostep) for Numerai Inc
/// @dev Security contact: security@numer.ai
/// @dev Version: 1.3.0
/// @notice The factory contract implements a standard interface for creating EIP-1167 clones of a given template contract.
///         The create functions accept abi-encoded calldata used to initialize the spawned templates.
contract Factory is Spawner, iFactory {

    address[] private _instances;
    mapping(address => address) private _instanceCreator;

    /* NOTE: The following items can be hardcoded as constant to save ~200 gas/create */
    address private _templateContract;
    bytes4 private _initSelector;
    address private _instanceRegistry;
    bytes4 private _instanceType;

    event InstanceCreated(address indexed instance, address indexed creator, bytes callData);

    /// @notice Constructior
    /// @param instanceRegistry address of the registry where all clones are registered.
    /// @param templateContract address of the template used for making clones.
    /// @param instanceType bytes4 identifier for the type of the factory. This must match the type of the registry.
    /// @param initSelector bytes4 selector for the template initialize function.
    function _initialize(address instanceRegistry, address templateContract, bytes4 instanceType, bytes4 initSelector) internal {
        // set instance registry
        _instanceRegistry = instanceRegistry;
        // set logic contract
        _templateContract = templateContract;
        // set initSelector
        _initSelector = initSelector;
        // validate correct instance registry
        require(instanceType == iRegistry(instanceRegistry).getInstanceType(), 'incorrect instance type');
        // set instanceType
        _instanceType = instanceType;
    }

    // IFactory methods

    /// @notice Create clone of the template using a nonce.
    ///         The nonce is unique for clones with the same initialization calldata.
    ///         The nonce can be used to determine the address of the clone before creation.
    ///         The callData must be prepended by the function selector of the template's initialize function and include all parameters.
    /// @param callData bytes blob of abi-encoded calldata used to initialize the template.
    /// @return instance address of the clone that was created.
    function create(bytes memory callData) public returns (address instance) {
        // deploy new contract: initialize it & write minimal proxy to runtime.
        instance = Spawner._spawn(msg.sender, getTemplate(), callData);

        _createHelper(instance, callData);

        return instance;
    }

    /// @notice Create clone of the template using a salt.
    ///         The salt must be unique for clones with the same initialization calldata.
    ///         The salt can be used to determine the address of the clone before creation.
    ///         The callData must be prepended by the function selector of the template's initialize function and include all parameters.
    /// @param callData bytes blob of abi-encoded calldata used to initialize the template.
    /// @return instance address of the clone that was created.
    function createSalty(bytes memory callData, bytes32 salt) public returns (address instance) {
        // deploy new contract: initialize it & write minimal proxy to runtime.
        instance = Spawner._spawnSalty(msg.sender, getTemplate(), callData, salt);

        _createHelper(instance, callData);

        return instance;
    }

    /// @notice Private function to help with the creation of the clone.
    ///         Stores the address of the clone in this contract.
    ///         Stores the creator of the clone in this contract.
    ///         Registers the address of the clone in the registry. Fails if the factory is deprecated.
    ///         Emits standard InstanceCreated event
    /// @param instance address The address of the clone that was created.
    /// @param callData bytes The initialization calldata to use on the clone.
    function _createHelper(address instance, bytes memory callData) private {
        // add the instance to the array
        _instances.push(instance);
        // set instance creator
        _instanceCreator[instance] = msg.sender;
        // add the instance to the instance registry
        iRegistry(getInstanceRegistry()).register(instance, msg.sender, uint80(0));
        // emit event
        emit InstanceCreated(instance, msg.sender, callData);
    }

    /// @notice Get the address of an instance for a given salt
    function getSaltyInstance(
        address creator,
        bytes memory callData,
        bytes32 salt
    ) public view returns (address instance, bool validity) {
        return Spawner._getSaltyTarget(creator, getTemplate(), callData, salt);
    }

    function getNextNonceInstance(
        address creator,
        bytes memory callData
    ) public view returns (address target) {
        return Spawner._getNextNonceTarget(creator, getTemplate(), callData);
    }

    function getInstanceCreator(address instance) public view returns (address creator) {
        return _instanceCreator[instance];
    }

    function getInstanceType() public view returns (bytes4 instanceType) {
        return _instanceType;
    }

    function getInitSelector() public view returns (bytes4 initSelector) {
        return _initSelector;
    }

    function getInstanceRegistry() public view returns (address instanceRegistry) {
        return _instanceRegistry;
    }

    function getTemplate() public view returns (address template) {
        return _templateContract;
    }

    function getInstanceCount() public view returns (uint256 count) {
        return _instances.length;
    }

    function getInstance(uint256 index) public view returns (address instance) {
        require(index < _instances.length, "index out of range");
        return _instances[index];
    }

    function getInstances() public view returns (address[] memory instances) {
        return _instances;
    }

    // Note: startIndex is inclusive, endIndex exclusive
    function getPaginatedInstances(uint256 startIndex, uint256 endIndex) public view returns (address[] memory instances) {
        require(startIndex < endIndex, "startIndex must be less than endIndex");
        require(endIndex <= _instances.length, "end index out of range");

        // initialize fixed size memory array
        address[] memory range = new address[](endIndex - startIndex);

        // Populate array with addresses in range
        for (uint256 i = startIndex; i < endIndex; i++) {
            range[i - startIndex] = _instances[i];
        }

        // return array of addresses
        return range;
    }

}


/// @title BurnNMR
/// @author Stephane Gosselin (@thegostep) for Numerai Inc
/// @dev Security contact: security@numer.ai
/// @dev Version: 1.3.0
/// @notice This module simplifies calling NMR burn functions using regular openzeppelin ERC20Burnable interface and revert on failure.
///         This helper is required given the non-standard implementation of the NMR burn functions: https://github.com/numerai/contract
contract BurnNMR {

    // address of the token
    address private constant _NMRToken = address(0x1776e1F26f98b1A5dF9cD347953a26dd3Cb46671);
    // uniswap exchange of the token
    address private constant _NMRExchange = address(0x2Bf5A5bA29E60682fC56B2Fcf9cE07Bef4F6196f);

    /// @notice Burns a specific amount of NMR from this contract.
    /// @param value uint256 The amount of NMR (18 decimals) to be burned.
    function _burn(uint256 value) internal {
        require(iNMR(_NMRToken).mint(value), "nmr burn failed");
    }

    /// @notice Burns a specific amount of NMR from the target address and decrements allowance.
    /// @param from address The account whose tokens will be burned.
    /// @param value uint256 The amount of NMR (18 decimals) to be burned.
    function _burnFrom(address from, uint256 value) internal {
        require(iNMR(_NMRToken).numeraiTransfer(from, value), "nmr burnFrom failed");
    }

    /// @notice Get the NMR token address.
    /// @return token address The NMR token address.
    function getTokenAddress() internal pure returns (address token) {
        token = _NMRToken;
    }

    /// @notice Get the NMR Uniswap exchange address.
    /// @return token address The NMR Uniswap exchange address.
    function getExchangeAddress() internal pure returns (address exchange) {
        exchange = _NMRExchange;
    }

}




/// @title BurnDAI
/// @author Stephane Gosselin (@thegostep) for Numerai Inc
/// @dev Security contact: security@numer.ai
/// @dev Version: 1.3.0
/// @notice This module allows for burning DAI tokens by exchanging them for NMR on uniswap and burning the NMR.
contract BurnDAI is BurnNMR {

    // address of the token
    address private constant _DAIToken = address(0x6B175474E89094C44Da98b954EedeAC495271d0F);
    // uniswap exchange of the token
    address private constant _DAIExchange = address(0x2a1530C4C41db0B0b2bB646CB5Eb1A67b7158667);

    /// @notice Burns a specific amount of DAI from the target address and decrements allowance.
    /// @dev This implementation has no frontrunning protection.
    /// @param from address The account whose tokens will be burned.
    /// @param value uint256 The amount of DAI (18 decimals) to be burned.
    function _burnFrom(address from, uint256 value) internal {

        // transfer dai to this contract
        IERC20(_DAIToken).transferFrom(from, address(this), value);

        // butn nmr
        _burn(value);
    }

    /// @notice Burns a specific amount of DAI from this contract.
    /// @dev This implementation has no frontrunning protection.
    /// @param value uint256 The amount of DAI (18 decimals) to be burned.
    function _burn(uint256 value) internal {

        // approve uniswap for token transfer
        IERC20(_DAIToken).approve(_DAIExchange, value);

        // swap dai for nmr
        uint256 tokens_sold = value;
        (uint256 min_tokens_bought, uint256 min_eth_bought) = getExpectedSwapAmount(tokens_sold);
        uint256 deadline = now;
        uint256 tokens_bought = UniswapExchangeInterface(_DAIExchange).tokenToTokenSwapInput(
            tokens_sold,
            min_tokens_bought,
            min_eth_bought,
            deadline,
            BurnNMR.getTokenAddress()
        );

        // burn nmr
        BurnNMR._burn(tokens_bought);
    }

    /// @notice Get the amount of NMR and ETH required to sell a given amount of DAI.
    /// @param amountDAI uint256 The amount of DAI (18 decimals) to sell.
    /// @param amountNMR uint256 The amount of NMR (18 decimals) required.
    /// @param amountETH uint256 The amount of ETH (18 decimals) required.
    function getExpectedSwapAmount(uint256 amountDAI) internal view returns (uint256 amountNMR, uint256 amountETH) {
        amountETH = UniswapExchangeInterface(_DAIExchange).getTokenToEthInputPrice(amountDAI);
        amountNMR = UniswapExchangeInterface(BurnNMR.getExchangeAddress()).getEthToTokenInputPrice(amountETH);
        return (amountNMR, amountETH);
    }

    /// @notice Get the DAI token address.
    /// @return token address The DAI token address.
    function getTokenAddress() internal pure returns (address token) {
        token = _DAIToken;
    }

    /// @notice Get the DAI Uniswap exchange address.
    /// @return token address The DAI Uniswap exchange address.
    function getExchangeAddress() internal pure returns (address exchange) {
        exchange = _DAIExchange;
    }

}

/// @title TokenManager
/// @author Stephane Gosselin (@thegostep) for Numerai Inc
/// @dev Security contact: security@numer.ai
/// @dev Version: 1.3.0
/// @notice This module provides a standard interface for interacting with supported ERC20 tokens.
contract TokenManager is BurnDAI {

    enum Tokens {NaN, NMR, DAI}

    /// @notice Get the address of the given token ID.
    /// @param tokenID TokenManager.Tokens ID of the ERC20 token.
    /// @return tokenAddress address of the ERC20 token.
    function getTokenAddress(Tokens tokenID) public pure returns (address tokenAddress) {
        if (tokenID == Tokens.DAI)
            return BurnDAI.getTokenAddress();
        if (tokenID == Tokens.NMR)
            return BurnNMR.getTokenAddress();
        return address(0);
    }

    /// @notice Get the address of the uniswap exchange for given token ID.
    /// @param tokenID TokenManager.Tokens ID of the ERC20 token.
    /// @return exchangeAddress address of the uniswap exchange.
    function getExchangeAddress(Tokens tokenID) public pure returns (address exchangeAddress) {
        if (tokenID == Tokens.DAI)
            return BurnDAI.getExchangeAddress();
        if (tokenID == Tokens.NMR)
            return BurnNMR.getExchangeAddress();
        return address(0);
    }

    modifier onlyValidTokenID(Tokens tokenID) {
        require(isValidTokenID(tokenID), 'invalid tokenID');
        _;
    }

    /// @notice Validate the token ID is a supported token.
    /// @param tokenID TokenManager.Tokens ID of the ERC20 token.
    /// @return validity bool true if the token is supported.
    function isValidTokenID(Tokens tokenID) internal pure returns (bool validity) {
        return tokenID == Tokens.NMR || tokenID == Tokens.DAI;
    }

    /// @notice ERC20 ransfer.
    /// @param tokenID TokenManager.Tokens ID of the ERC20 token.
    /// @param to address of the recipient.
    /// @param value uint256 amount of tokens.
    function _transfer(Tokens tokenID, address to, uint256 value) internal onlyValidTokenID(tokenID) {
        require(IERC20(getTokenAddress(tokenID)).transfer(to, value), 'token transfer failed');
    }

    /// @notice ERC20 TransferFrom
    /// @param tokenID TokenManager.Tokens ID of the ERC20 token.
    /// @param from address to spend from.
    /// @param to address of the recipient.
    /// @param value uint256 amount of tokens.
    function _transferFrom(Tokens tokenID, address from, address to, uint256 value) internal onlyValidTokenID(tokenID) {
        require(IERC20(getTokenAddress(tokenID)).transferFrom(from, to, value), 'token transfer failed');
    }

    /// @notice ERC20 Burn
    /// @param tokenID TokenManager.Tokens ID of the ERC20 token.
    /// @param value uint256 amount of tokens.
    function _burn(Tokens tokenID, uint256 value) internal onlyValidTokenID(tokenID) {
        if (tokenID == Tokens.DAI) {
            BurnDAI._burn(value);
        } else if (tokenID == Tokens.NMR) {
            BurnNMR._burn(value);
        }
    }

    /// @notice ERC20 BurnFrom
    /// @param tokenID TokenManager.Tokens ID of the ERC20 token.
    /// @param from address to burn from.
    /// @param value uint256 amount of tokens.
    function _burnFrom(Tokens tokenID, address from, uint256 value) internal onlyValidTokenID(tokenID) {
        if (tokenID == Tokens.DAI) {
            BurnDAI._burnFrom(from, value);
        } else if (tokenID == Tokens.NMR) {
            BurnNMR._burnFrom(from, value);
        }
    }

    /// @notice ERC20 Approve
    /// @param tokenID TokenManager.Tokens ID of the ERC20 token.
    /// @param spender address of the spender.
    /// @param value uint256 amount of tokens.
    function _approve(Tokens tokenID, address spender, uint256 value) internal onlyValidTokenID(tokenID) {
        if (tokenID == Tokens.DAI) {
            require(IERC20(BurnDAI.getTokenAddress()).approve(spender, value), 'token approval failed');
        } else if (tokenID == Tokens.NMR) {
            address nmr = BurnNMR.getTokenAddress();
            uint256 currentAllowance = IERC20(nmr).allowance(msg.sender, spender);
            require(iNMR(nmr).changeApproval(spender, currentAllowance, value), 'token approval failed');
        }
    }

    /// @notice ERC20 TotalSupply
    /// @param tokenID TokenManager.Tokens ID of the ERC20 token.
    /// @return value uint256 amount of tokens.
    function totalSupply(Tokens tokenID) internal view onlyValidTokenID(tokenID) returns (uint256 value) {
        return IERC20(getTokenAddress(tokenID)).totalSupply();
    }

    /// @notice ERC20 BalanceOf
    /// @param tokenID TokenManager.Tokens ID of the ERC20 token.
    /// @param who address of the owner.
    /// @return value uint256 amount of tokens.
    function balanceOf(Tokens tokenID, address who) internal view onlyValidTokenID(tokenID) returns (uint256 value) {
        return IERC20(getTokenAddress(tokenID)).balanceOf(who);
    }

    /// @notice ERC20 Allowance
    /// @param tokenID TokenManager.Tokens ID of the ERC20 token.
    /// @param owner address of the owner.
    /// @param spender address of the spender.
    /// @return value uint256 amount of tokens.
    function allowance(Tokens tokenID, address owner, address spender) internal view onlyValidTokenID(tokenID) returns (uint256 value) {
        return IERC20(getTokenAddress(tokenID)).allowance(owner, spender);
    }
}




/// @title Deposit
/// @author Stephane Gosselin (@thegostep) for Numerai Inc
/// @dev Security contact: security@numer.ai
/// @dev Version: 1.3.0
/// @dev State Machine: https://github.com/erasureprotocol/erasure-protocol/blob/release/v1.3.x/docs/state-machines/modules/Deposit.png
/// @notice This module allows for tracking user deposits for fungible tokens.
contract Deposit {

    using SafeMath for uint256;

    mapping(uint256 => mapping(address => uint256)) private _deposit;

    event DepositIncreased(TokenManager.Tokens tokenID, address user, uint256 amount, uint256 newDeposit);
    event DepositDecreased(TokenManager.Tokens tokenID, address user, uint256 amount, uint256 newDeposit);

    /// @notice Increase the deposit of a user.
    /// @param tokenID TokenManager.Tokens ID of the ERC20 token. This ID must be one of the IDs supported by TokenManager.
    /// @param user address of the user.
    /// @param amountToAdd uint256 amount by which to increase the deposit.
    /// @return newDeposit uint256 amount of the updated deposit.
    function _increaseDeposit(TokenManager.Tokens tokenID, address user, uint256 amountToAdd) internal returns (uint256 newDeposit) {
        // calculate new deposit amount
        newDeposit = _deposit[uint256(tokenID)][user].add(amountToAdd);

        // set new stake to storage
        _deposit[uint256(tokenID)][user] = newDeposit;

        // emit event
        emit DepositIncreased(tokenID, user, amountToAdd, newDeposit);

        // return
        return newDeposit;
    }

    /// @notice Decrease the deposit of a user.
    /// @param tokenID TokenManager.Tokens ID of the ERC20 token. This ID must be one of the IDs supported by TokenManager.
    /// @param user address of the user.
    /// @param amountToRemove uint256 amount by which to decrease the deposit.
    /// @return newDeposit uint256 amount of the updated deposit.
    function _decreaseDeposit(TokenManager.Tokens tokenID, address user, uint256 amountToRemove) internal returns (uint256 newDeposit) {
        // get current deposit
        uint256 currentDeposit = _deposit[uint256(tokenID)][user];

        // check if sufficient deposit
        require(currentDeposit >= amountToRemove, "insufficient deposit to remove");

        // calculate new deposit amount
        newDeposit = currentDeposit.sub(amountToRemove);

        // set new stake to storage
        _deposit[uint256(tokenID)][user] = newDeposit;

        // emit event
        emit DepositDecreased(tokenID, user, amountToRemove, newDeposit);

        // return
        return newDeposit;
    }

    /// @notice Set the deposit of a user to zero.
    /// @param tokenID TokenManager.Tokens ID of the ERC20 token. This ID must be one of the IDs supported by TokenManager.
    /// @param user address of the user.
    /// @return amountRemoved uint256 amount removed from deposit.
    function _clearDeposit(TokenManager.Tokens tokenID, address user) internal returns (uint256 amountRemoved) {
        // get current deposit
        uint256 currentDeposit = _deposit[uint256(tokenID)][user];

        // remove deposit
        _decreaseDeposit(tokenID, user, currentDeposit);

        // return
        return currentDeposit;
    }

    // view functions

    /// @notice Get the current deposit of a user.
    /// @param tokenID TokenManager.Tokens ID of the ERC20 token. This ID must be one of the IDs supported by TokenManager.
    /// @param user address of the user.
    /// @return deposit uint256 current amount of the deposit.
    function getDeposit(TokenManager.Tokens tokenID, address user) internal view returns (uint256 deposit) {
        return _deposit[uint256(tokenID)][user];
    }

}





/// @title Staking
/// @author Stephane Gosselin (@thegostep) for Numerai Inc
/// @dev Security contact: security@numer.ai
/// @dev Version: 1.3.0
/// @dev State Machine: https://github.com/erasureprotocol/erasure-protocol/blob/release/v1.3.x/docs/state-machines/modules/Staking.png
/// @notice This module wraps the Deposit functions and the ERC20 functions to provide combined actions.
contract Staking is Deposit, TokenManager {

    using SafeMath for uint256;

    event StakeBurned(TokenManager.Tokens tokenID, address staker, uint256 amount);

    /// @notice Transfer and deposit ERC20 tokens to this contract.
    /// @param tokenID TokenManager.Tokens ID of the ERC20 token. This ID must be one of the IDs supported by TokenManager.
    /// @param staker Address of the staker who owns the stake.
    /// @param funder Address of the funder from whom the tokens are transfered.
    /// @param amountToAdd uint256 amount of tokens (18 decimals) to be added to the stake.
    /// @return newStake uint256 amount of tokens (18 decimals) remaining in the stake.
    function _addStake(TokenManager.Tokens tokenID, address staker, address funder, uint256 amountToAdd) internal returns (uint256 newStake) {
        // update deposit
        newStake = Deposit._increaseDeposit(tokenID, staker, amountToAdd);

        // transfer the stake amount
        TokenManager._transferFrom(tokenID, funder, address(this), amountToAdd);

        // explicit return
        return newStake;
    }

    /// @notice Withdraw some deposited stake and transfer to recipient.
    /// @param tokenID TokenManager.Tokens ID of the ERC20 token. This ID must be one of the IDs supported by TokenManager.
    /// @param staker Address of the staker who owns the stake.
    /// @param recipient Address of the recipient who receives the tokens.
    /// @param amountToTake uint256 amount of tokens (18 decimals) to be remove from the stake.
    /// @return newStake uint256 amount of tokens (18 decimals) remaining in the stake.
    function _takeStake(TokenManager.Tokens tokenID, address staker, address recipient, uint256 amountToTake) internal returns (uint256 newStake) {
        // update deposit
        newStake = Deposit._decreaseDeposit(tokenID, staker, amountToTake);

        // transfer the stake amount
        TokenManager._transfer(tokenID, recipient, amountToTake);

        // explicit return
        return newStake;
    }

    /// @notice Withdraw all deposited stake and transfer to recipient.
    /// @param tokenID TokenManager.Tokens ID of the ERC20 token. This ID must be one of the IDs supported by TokenManager.
    /// @param staker Address of the staker who owns the stake.
    /// @param recipient Address of the recipient who receives the tokens.
    /// @return amountTaken uint256 amount of tokens (18 decimals) taken from the stake.
    function _takeFullStake(TokenManager.Tokens tokenID, address staker, address recipient) internal returns (uint256 amountTaken) {
        // get deposit
        uint256 currentDeposit = Deposit.getDeposit(tokenID, staker);

        // take full stake
        _takeStake(tokenID, staker, recipient, currentDeposit);

        // return
        return currentDeposit;
    }

    /// @notice Burn some deposited stake.
    /// @param tokenID TokenManager.Tokens ID of the ERC20 token. This ID must be one of the IDs supported by TokenManager.
    /// @param staker Address of the staker who owns the stake.
    /// @param amountToBurn uint256 amount of tokens (18 decimals) to be burn from the stake.
    /// @return newStake uint256 amount of tokens (18 decimals) remaining in the stake.
    function _burnStake(TokenManager.Tokens tokenID, address staker, uint256 amountToBurn) internal returns (uint256 newStake) {
        // update deposit
        uint256 newDeposit = Deposit._decreaseDeposit(tokenID, staker, amountToBurn);

        // burn the stake amount
        TokenManager._burn(tokenID, amountToBurn);

        // emit event
        emit StakeBurned(tokenID, staker, amountToBurn);

        // return
        return newDeposit;
    }

    /// @notice Burn all deposited stake.
    /// @param tokenID TokenManager.Tokens ID of the ERC20 token. This ID must be one of the IDs supported by TokenManager.
    /// @param staker Address of the staker who owns the stake.
    /// @return amountBurned uint256 amount of tokens (18 decimals) taken from the stake.
    function _burnFullStake(TokenManager.Tokens tokenID, address staker) internal returns (uint256 amountBurned) {
        // get deposit
        uint256 currentDeposit = Deposit.getDeposit(tokenID, staker);

        // burn full stake
        _burnStake(tokenID, staker, currentDeposit);

        // return
        return currentDeposit;
    }

}







/// @title Feed
/// @author Stephane Gosselin (@thegostep) for Numerai Inc
/// @dev Security contact: security@numer.ai
/// @dev Version: 1.3.0
/// @notice A Feed allows for the creator to build a track record of timestamped submissions and deposit a stake to signal legitimacy.
contract Feed is Staking, ProofHashes, Operated, EventMetadata, Template {

    event Initialized(address operator, bytes metadata);

    /// @notice Constructor
    /// @dev Access Control: only factory
    ///      State Machine: before all
    /// @param operator Address of the operator that overrides access control
    /// @param metadata Data (any format) to emit as event on initialization
    function initialize(
        address operator,
        bytes memory metadata
    ) public initializeTemplate() {
        // set operator
        if (operator != address(0)) {
            Operated._setOperator(operator);
        }

        // set metadata
        if (metadata.length != 0) {
            EventMetadata._setMetadata(metadata);
        }

        // log initialization params
        emit Initialized(operator, metadata);
    }

    // state functions

    /// @notice Submit proofhash to add to feed
    /// @dev Access Control: creator OR operator
    ///      State Machine: anytime
    /// @param proofHash Proofhash (bytes32) sha256 hash of timestampled data
    function submitHash(bytes32 proofHash) public {
        // only operator or creator
        require(Template.isCreator(msg.sender) || Operated.isOperator(msg.sender), "only operator or creator");

        // submit proofHash
        ProofHashes._submitHash(proofHash);
    }

    /// @notice Deposit one of the supported ERC20 token.
    ///         - This deposit can be withdrawn at any time by the owner of the feed.
    ///         - This requires the caller to do ERC20 approval for this contract for `amountToAdd`.
    /// @dev Access Control: creator OR operator
    ///      State Machine: anytime
    /// @param tokenID TokenManager.Tokens id of the ERC20 token.
    /// @param amountToAdd uint256 amount of ERC20 tokens (18 decimals) to add.
    function depositStake(TokenManager.Tokens tokenID, uint256 amountToAdd) public returns (uint256 newStake) {
        // only operator or creator
        require(Template.isCreator(msg.sender) || Operated.isOperator(msg.sender), "only operator or creator");

        // transfer and add tokens to stake
        return Staking._addStake(tokenID, Template.getCreator(), msg.sender, amountToAdd);
    }

    /// @notice Withdraw one of the supported ERC20 token.
    /// @dev Access Control: creator OR operator
    ///      State Machine: anytime
    /// @param tokenID TokenManager.Tokens id of the ERC20 token.
    /// @param amountToRemove uint256 amount of ERC20 tokens (18 decimals) to add.
    function withdrawStake(TokenManager.Tokens tokenID, uint256 amountToRemove) public returns (uint256 newStake) {
        // only operator or creator
        require(Template.isCreator(msg.sender) || Operated.isOperator(msg.sender), "only operator or creator");

        // transfer and remove tokens from stake
        return Staking._takeStake(tokenID, Template.getCreator(), Template.getCreator(), amountToRemove);
    }

    /// @notice Emit metadata event
    /// @dev Access Control: creator OR operator
    ///      State Machine: anytime
    /// @param metadata Data (any format) to emit as event
    function setMetadata(bytes memory metadata) public {
        // only operator or creator
        require(Template.isCreator(msg.sender) || Operated.isOperator(msg.sender), "only operator or creator");

        // set metadata
        EventMetadata._setMetadata(metadata);
    }

    /// @notice Called by the operator to transfer control to new operator
    /// @dev Access Control: operator
    ///      State Machine: anytime
    /// @param operator Address of the new operator
    function transferOperator(address operator) public {
        // restrict access
        require(Operated.isOperator(msg.sender), "only operator");

        // transfer operator
        Operated._transferOperator(operator);
    }

    /// @notice Called by the operator to renounce control
    /// @dev Access Control: operator
    ///      State Machine: anytime
    function renounceOperator() public {
        // restrict access
        require(Operated.isOperator(msg.sender), "only operator");

        // renounce operator
        Operated._renounceOperator();
    }

    /// @notice Get the current stake for a given ERC20 token.
    /// @dev Access Control: creator OR operator
    ///      State Machine: anytime
    /// @param tokenID TokenManager.Tokens id of the ERC20 token.
    function getStake(TokenManager.Tokens tokenID) public view returns (uint256 stake) {
        return Deposit.getDeposit(tokenID, Template.getCreator());
    }

}




/// @title Feed_Factory
/// @author Stephane Gosselin (@thegostep) for Numerai Inc
/// @dev Security contact: security@numer.ai
/// @dev Version: 1.3.0
/// @notice This factory is used to deploy instances of the template contract.
///         New instances can be created with the following functions:
///             `function create(bytes calldata initData) external returns (address instance);`
///             `function createSalty(bytes calldata initData, bytes32 salt) external returns (address instance);`
///         The `initData` parameter is ABI encoded calldata to use on the initialize function of the instance after creation.
///         The optional `salt` parameter can be used to deterministically generate the instance address instead of using a nonce.
///         See documentation of the template for additional details on initialization parameters.
///         The template contract address can be optained with the following function:
///             `function getTemplate() external view returns (address template);`
contract Feed_Factory is Factory {

    constructor(address instanceRegistry, address templateContract) public {
        Feed template;

        // set instance type
        bytes4 instanceType = bytes4(keccak256(bytes('Post')));
        // set initSelector
        bytes4 initSelector = template.initialize.selector;
        // initialize factory params
        Factory._initialize(instanceRegistry, templateContract, instanceType, initSelector);
    }

}
