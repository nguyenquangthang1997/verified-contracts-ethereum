pragma solidity ^0.6.0;
pragma experimental ABIEncoderV2;

import "./FixedPoint.sol";
import "./Liquidatable.sol";


contract ExpiringMultiParty is Liquidatable {
    constructor(ConstructorParams memory params) public Liquidatable(params) {}
}
