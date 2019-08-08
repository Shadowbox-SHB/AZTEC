pragma solidity >=0.5.0 <0.6.0;

import "openzeppelin-solidity/contracts/token/ERC20/ERC20.sol";
import "openzeppelin-solidity/contracts/math/SafeMath.sol";
import "openzeppelin-solidity/contracts/ownership/Ownable.sol";

import "../../interfaces/IAZTEC.sol";
import "../../libs/VersioningUtils.sol";
import "./interfaces/NoteRegistryBehaviour.sol";
import "./interfaces/NoteRegistryFactory.sol";
import "./proxies/AdminUpgradeabilityProxy.sol";

/**
 * @title NoteRegistryManager
 * @author AZTEC
 * @dev NoteRegistryManager will be inherrited by ACE, and its purpose is to manage the entire
        lifecycle of noteRegistries and of
        factories. It defines the methods which are used to deploy and upgrade registries, the methods
        to enact state changes sent by
        the owner of a registry, and it also manages the list of factories which are available.
 *
 * Copyright Spilsbury Holdings Ltd 2019. All rights reserved.
 **/
contract NoteRegistryManager is IAZTEC, Ownable {
    using SafeMath for uint256;
    using VersioningUtils for uint24;

    /**
    * @dev event transmitted if and when a factory gets registered.
    */
    event SetFactory(
        uint8 indexed epoch,
        uint8 indexed cryptoSystem,
        uint8 indexed assetType,
        address factoryAddress
    );

    event CreateNoteRegistry(
        address registryOwner,
        address registryAddress,
        uint256 scalingFactor,
        address linkedTokenAddress,
        bool canAdjustSupply,
        bool canConvert
    );

    // Every user has their own note registry
    mapping(address => NoteRegistryBehaviour) public registries;
    mapping(address => IERC20) internal publicTokens;
    mapping(address => uint24) internal registryFactories;
    /**
    * @dev index of available factories, using very similar structure to proof registry in ACE.sol.
    * The structure of the index is (epoch, cryptoSystem, assetType).
    */
    address[0x100][0x100][0x10000] factories;


    uint8 public defaultRegistryEpoch = 1;
    uint8 public defaultCryptoSystem = 1;

    mapping(bytes32 => bool) public validatedProofs;

    modifier onlyRegistry() {
        require(registryFactories[msg.sender] != uint24(0), "method can only be called from a noteRegistry");
        _;
    }

    function incrementDefaultRegistryEpoch() public onlyOwner {
        defaultRegistryEpoch = defaultRegistryEpoch + 1;
    }

    function setDefaultCryptoSystem(uint8 _defaultCryptoSystem) public onlyOwner {
        defaultCryptoSystem = _defaultCryptoSystem;
    }

    /**
    * @dev Register a new Factory, iff no factory for that ID exists.
            The epoch of any new factory must be at least as big as
            the default registry epoch. Each asset type for each cryptosystem for
            each epoch should have a note registry
    *
    * @param _factoryId - uint24 which contains 3 uint8s representing (epoch, cryptoSystem, assetType)
    * @param _factoryAddress - address of the deployed factory
    */
    function setFactory(uint24 _factoryId, address _factoryAddress) public onlyOwner {
        require(_factoryAddress != address(0x0), "expected the factory contract to exist");
        (uint8 epoch, uint8 cryptoSystem, uint8 assetType) = _factoryId.getVersionComponents();
        require(epoch <= defaultRegistryEpoch, "the factory epoch cannot be bigger than the latest epoch");
        require(factories[epoch][cryptoSystem][assetType] == address(0x0), "existing factories cannot be modified");
        factories[epoch][cryptoSystem][assetType] = _factoryAddress;
        emit SetFactory(epoch, cryptoSystem, assetType, _factoryAddress);
    }

    /**
    * @dev Get the factory address associated with a particular factoryId. Fail if resulting address is 0x0.
    *
    * @param _factoryId - uint24 which contains 3 uint8s representing (epoch, cryptoSystem, assetType)
    */
    function getFactoryAddress(uint24 _factoryId) public view returns (address factoryAddress) {
        bool queryInvalid;
        assembly {
            // To compute the storage key for factoryAddress[epoch][cryptoSystem][assetType], we do the following:
            // 1. get the factoryAddress slot
            // 2. add (epoch * 0x10000) to the slot
            // 3. add (cryptoSystem * 0x100) to the slot
            // 4. add (assetType) to the slot
            // i.e. the range of storage pointers allocated to factoryAddress ranges from
            // factoryAddress_slot to (0xffff * 0x10000 + 0xff * 0x100 + 0xff = factoryAddress_slot 0xffffffff)

            // Conveniently, the multiplications we have to perform on epoch, cryptoSystem and assetType correspond
            // to their byte positions in _factoryId.
            // i.e. (epoch * 0x10000) = and(_factoryId, 0xff0000)
            // and  (cryptoSystem * 0x100) = and(_factoryId, 0xff00)
            // and  (assetType) = and(_factoryId, 0xff)

            // Putting this all together. The storage slot offset from '_factoryId' is...
            // (_factoryId & 0xffff0000) + (_factoryId & 0xff00) + (_factoryId & 0xff)
            // i.e. the storage slot offset IS the value of _factoryId
            factoryAddress := sload(add(_factoryId, factories_slot))

            queryInvalid := iszero(factoryAddress)
        }

        // wrap both require checks in a single if test. This means the happy path only has 1 conditional jump
        if (queryInvalid) {
            require(factoryAddress != address(0x0), "expected the factory address to exist");
        }
    }

    /**
    * @dev called when a mintable and convertible asset wants to perform an
            action which putts the zero-knowledge and public
            balance out of balance. For example, if minting in zero-knowledge, some
            public tokens need to be added to the pool
            managed by ACE, otherwise any private->public conversion runs the risk of not
            having any public tokens to send.
    *
    * @param _value the value to be added
    */
    function supplementTokens(uint256 _value) external {
        NoteRegistryBehaviour registry = registries[msg.sender];
        require(address(registry) != address(0x0), "note registry does not exist");
        (
            address linkedToken,
            uint256 scalingFactor,
            ,,,
            bool canConvert,
            bool canAdjustSupply
        ) = registry.getRegistry();
        require(canConvert == true, "note registry does not have conversion rights");
        require(canAdjustSupply == true, "note registry does not have mint and burn rights");
        IERC20(linkedToken).transferFrom(msg.sender, address(this), _value.mul(scalingFactor));
        registry.incrementTotalSupply(_value);
    }

    /**
    * @dev Query the ACE for a previously validated proof
    * @notice This is a virtual function, that must be overwritten by the contract that inherits from NoteRegistry
    *
    * @param _proof - unique identifier for the proof in question and being validated
    * @param _proofHash - keccak256 hash of a bytes proofOutput argument. Used to identify the proof in question
    * @param _sender - address of the entity that originally validated the proof
    * @return boolean - true if the proof has previously been validated, false if not
    */
    function validateProofByHash(uint24 _proof, bytes32 _proofHash, address _sender) public view returns (bool);

    /**
    * @dev Default noteRegistry creation method. Doesn't take the id of the factory to use,
            but generates it based on defaults and on the passed flags.
    *
    * @param _linkedTokenAddress - address of any erc20 linked token (can not be 0x0 if canConvert is true)
    * @param _scalingFactor - defines the number of tokens that an AZTEC note value of 1 maps to.
    * @param _canAdjustSupply - whether the noteRegistry can make use of minting and burning
    * @param _canConvert - whether the noteRegistry can transfer value from private to public
        representation and vice versa
    */
    function createNoteRegistry(
        address _linkedTokenAddress,
        uint256 _scalingFactor,
        bool _canAdjustSupply,
        bool _canConvert
    ) public {
        uint8 assetType = getAssetTypeFromFlags(_canConvert, _canAdjustSupply);

        uint24 factoryId = computeVersionFromComponents(defaultRegistryEpoch, defaultCryptoSystem, assetType);

        createNoteRegistry(
            _linkedTokenAddress,
            _scalingFactor,
            _canAdjustSupply,
            _canConvert,
            factoryId
        );
    }

    /**
    * @dev NoteRegistry creation method. Takes an id of the factory to use.
    *
    * @param _linkedTokenAddress - address of any erc20 linked token (can not be 0x0 if canConvert is true)
    * @param _scalingFactor - defines the number of tokens that an AZTEC note value of 1 maps to.
    * @param _canAdjustSupply - whether the noteRegistry can make use of minting and burning
    * @param _canConvert - whether the noteRegistry can transfer value from private to public
        representation and vice versa
    * @param _factoryId - uint24 which contains 3 uint8s representing (epoch, cryptoSystem, assetType)
    */
    function createNoteRegistry(
        address _linkedTokenAddress,
        uint256 _scalingFactor,
        bool _canAdjustSupply,
        bool _canConvert,
        uint24 _factoryId
    ) public {
        require(address(registries[msg.sender]) == address(0x0), "address already has a linked note registry");
        (,, uint8 assetType) = _factoryId.getVersionComponents();
        // assetType is 0b00 where the bits represent (canAdjust, canConvert),
        // so assetType can be one of 1, 2, 3 where
        // 0 == no convert/no adjust (invalid)
        // 1 == can convert/no adjust
        // 2 == no convert/can adjust
        // 3 == can convert/can adjust
        uint8 flagAssetType = getAssetTypeFromFlags(_canConvert, _canAdjustSupply);
        require (flagAssetType != uint8(0), "can not create asset with convert and adjust flags set to false");
        require (flagAssetType == assetType, "expected note registry to match flags");

        address factory = getFactoryAddress(_factoryId);

        address behaviourAddress = NoteRegistryFactory(factory).deployNewBehaviourInstance();

        bytes memory behaviourInitialisation = abi.encodeWithSignature(
            "initialise(address,address,uint256,bool,bool)",
            address(this),
            _linkedTokenAddress,
            _scalingFactor,
            _canAdjustSupply,
            _canConvert
        );
        address proxy = address(new AdminUpgradeabilityProxy(
            behaviourAddress,
            factory,
            behaviourInitialisation
        ));

        registries[msg.sender] = NoteRegistryBehaviour(proxy);
        if (_canConvert) {
            require(_linkedTokenAddress != address(0x0), "expected the linked token address to exist");
            publicTokens[proxy] = IERC20(_linkedTokenAddress);
        }
        registryFactories[proxy] = _factoryId;
        emit CreateNoteRegistry(
            msg.sender,
            proxy,
            _scalingFactor,
            _linkedTokenAddress,
            _canAdjustSupply,
            _canConvert
        );
    }

    /**
    * @dev Method to upgrade the registry linked with the msg.sender to a new factory, based on _factoryId.
    * The submitted _factoryId must be of epoch equal or greater than previous _factoryId, and of the same assetType.
    *
    * @param _factoryId - uint24 which contains 3 uint8s representing (epoch, cryptoSystem, assetType)
    */
    function upgradeNoteRegistry(
        uint24 _factoryId
    ) public {
        NoteRegistryBehaviour registry = registries[msg.sender];
        require(address(registry) != address(0x0), "note registry for sender doesn't exist");
    
        (uint8 epoch,, uint8 assetType) = _factoryId.getVersionComponents();
        uint24 oldFactoryId = registryFactories[address(registry)];
        (uint8 oldEpoch,, uint8 oldAssetType) = oldFactoryId.getVersionComponents();
        require(epoch >= oldEpoch, "expected new registry to be of epoch equal or greater than existing registry");
        require(assetType == oldAssetType, "expected assetType to be the same for old and new registry");

        address factory = getFactoryAddress(_factoryId);
        address newBehaviour = NoteRegistryFactory(factory).deployNewBehaviourInstance();

        address oldFactory = getFactoryAddress(oldFactoryId);
        NoteRegistryFactory(oldFactory).upgradeBehaviour(address(registry), newBehaviour);
        registries[msg.sender] = NoteRegistryBehaviour(newBehaviour);
        registryFactories[address(registry)] = _factoryId;
    }

    /**
    * @dev Method used to transfer public tokens to or from ACE. This function should only be
        called by a registry, and only if the registry checks
        if a particular spend of public tokens has been approved. This method exists in order to
        make the client side API be able to authorise spends/transfer
        to a constant address (ACE). The alternative would be to have all public funds owned by the
        Proxy contract, but the client side API would then need to
        first find the deployed proxy for any zk asset. Prior to production, this needs to be moved to
        the second scenario.
    *
    * @param _from - address from which tokens are to be transfered
    * @param _to - address to which tokens are to be transfered
    * @param _value - value of tokens to be transfered
    */
    function transferFrom(address _from, address _to, uint256 _value)
        public
        onlyRegistry
    {
        if (_from == address(this)) {
            publicTokens[msg.sender].transfer(_to, _value);
        } else {
            publicTokens[msg.sender].transferFrom(_from, _to, _value);
        }
    }

    /**
    * @dev Update the state of the note registry according to transfer instructions issued by a
    * zero-knowledge proof. This method will verify that the relevant proof has been validated,
    * make sure the same proof has can't be re-used, and it then delegates to the relevant noteRegistry.
    *
    * @param _proof - unique identifier for a proof
    * @param _proofOutput - transfer instructions issued by a zero-knowledge proof
    * @param _proofSender - address of the entity sending the proof
    */
    function updateNoteRegistry(
        uint24 _proof,
        bytes memory _proofOutput,
        address _proofSender
    ) public {
        NoteRegistryBehaviour registry = registries[msg.sender];
        require(address(registry) != address(0x0), "note registry does not exist");
        bytes32 proofHash = keccak256(_proofOutput);
        require(
            validateProofByHash(_proof, proofHash, _proofSender) == true,
            "ACE has not validated a matching proof"
        );
        // clear record of valid proof - stops re-entrancy attacks and saves some gas
        validatedProofs[proofHash] = false;

        registry.updateNoteRegistry(_proof, _proofOutput);
    }

    /**
    * @dev Adds a public approval record to the noteRegistry, for use by ACE when it needs to transfer
        public tokens it holds to an external address. It needs to be associated with the hash of a proof.
    */
    function publicApprove(address _registryOwner, bytes32 _proofHash, uint256 _value) public {
        NoteRegistryBehaviour registry = registries[_registryOwner];
        require(address(registry) != address(0x0), "note registry does not exist");
        registry.publicApprove(msg.sender, _proofHash, _value);
    }

    /**
     * @dev Returns the registry for a given address.
     *
     * @param _owner - address of the registry owner in question
     *
     * @return linkedTokenAddress - public ERC20 token that is linked to the NoteRegistry. This is used to
     * transfer public value into and out of the system
     * @return scalingFactor - defines how many ERC20 tokens are represented by one AZTEC note
     * @return totalSupply - represents the total current supply of public tokens associated with a particular registry
     * @return confidentialTotalMinted - keccak256 hash of the note representing the total minted supply
     * @return confidentialTotalBurned - keccak256 hash of the note representing the total burned supply
     * @return canConvert - flag set by the owner to decide whether the registry has public to private, and
     * vice versa, conversion privilege
     * @return canAdjustSupply - determines whether the registry has minting and burning privileges
     */
    function getRegistry(address _owner) public view returns (
        address linkedToken,
        uint256 scalingFactor,
        uint256 totalSupply,
        bytes32 confidentialTotalMinted,
        bytes32 confidentialTotalBurned,
        bool canConvert,
        bool canAdjustSupply
    ) {
        NoteRegistryBehaviour registry = registries[_owner];
        return registry.getRegistry();
    }

    /**
     * @dev Returns the note for a given address and note hash.
     *
     * @param _registryOwner - address of the registry owner
     * @param _noteHash - keccak256 hash of the note coordiantes (gamma and sigma)
     *
     * @return status - status of the note, details whether the note is in a note registry
     * or has been destroyed
     * @return createdOn - time the note was created
     * @return destroyedOn - time the note was destroyed
     * @return noteOwner - address of the note owner
     */
    function getNote(address _registryOwner, bytes32 _noteHash) public view returns (
        uint8 status,
        uint40 createdOn,
        uint40 destroyedOn,
        address noteOwner
    ) {
        NoteRegistryBehaviour registry = registries[_registryOwner];
        return registry.getNote(_noteHash);
    }

    /**
    * @dev Internal utility method which converts two booleans into a uint8 where the first boolean
    * represents (1 == true, 0 == false) the bit in position 1, and the second boolean the bit in position 2.
    * The output is 1 for an asset which can convert between public and private, 2 for one with no conversion
    * but with the ability to mint and/or burn, and 3 for a mixed asset which can convert and mint/burn
    *
    */
    function getAssetTypeFromFlags(bool _canConvert, bool _canAdjust) internal pure returns (uint8 assetType) {
        uint8 convert = _canConvert ? 1 : 0;
        uint8 adjust = _canAdjust ? 2 : 0;

        assetType = convert + adjust;
    }

    /**
    * @dev Internal utility method which converts three uint8s into a uint24
    *
    */
    function computeVersionFromComponents(
        uint8 _first,
        uint8 _second,
        uint8 _third
    ) internal pure returns (uint24 version) {
        assembly {
            version := or(mul(_first, 0x10000), or(mul(_second, 0x100), _third))
        }
    }
}