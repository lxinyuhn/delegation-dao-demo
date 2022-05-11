// SPDX-License-Identifier: GPL-3.0-only
// This is a PoC to use the staking precompile wrapper as a Solidity developer.
pragma solidity >=0.8.0;

import "./StakingInterface.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Address.sol";

contract DelegationDAO {

    using SafeMath for uint256;
    
    // Possible states for the DAO to be in:
    // COLLECTING: the DAO is collecting funds before creating a delegation once the minimum delegation stake has been reached
    // STAKING: the DAO has an active delegation
    // REVOKING: the DAO has scheduled a delegation revoke
    // REVOKED: the scheduled revoke has been executed
    enum daoState{ COLLECTING, STAKING, REVOKING, REVOKED }

    // Current state that the DAO is in
    daoState public currentState; 

    // Member stakes (doesnt include rewards, represents member shares)
    mapping(address => uint256) public memberStakes;
    
    // Total Staking Pool (doesnt include rewards, represents total shares)
    uint256 public totalStake;

    // The ParachainStaking wrapper at the known pre-compile address. This will be used to make
    // all calls to the underlying staking solution
    ParachainStaking public staking;
    
    // Minimum Delegation Amount
    uint256 public constant minDelegationStk = 5 ether;
    
    // Moonbeam Staking Precompile address
    address public constant stakingPrecompileAddress = 0x0000000000000000000000000000000000000800;

    // The collator that this DAO is currently nominating
    address public target;

    bool public revokeState;
    address[] public revokeVoter;
    uint256 public totalRevokeVote;

    bool public resetState;
    address[] public resetVoter;
    uint256 public totalResetVote;


    // Event for a member deposit
    event deposit(address indexed _from, uint _value);

    // Event for a member withdrawal
    event withdrawal(address indexed _from, address indexed _to, uint _value);

    // Initialize a new DelegationDao dedicated to delegating to the given collator target.
    constructor(address _target) {
        
        //Sets the collator that this DAO nominating
        target = _target;
        
        // Initializes Moonbeam's parachain staking precompile
        staking = ParachainStaking(stakingPrecompileAddress);

        //Initialize the DAO state
        currentState = daoState.COLLECTING;        
    }

    // Increase member stake via a payable function and automatically stake the added amount if possible
    function add_stake() external payable {
        if (currentState == daoState.STAKING ) {
            // Sanity check
            if(!staking.is_delegator(address(this))){
                 revert("The DAO is in an inconsistent state.");
            }
            memberStakes[msg.sender] = memberStakes[msg.sender].add(msg.value);
            totalStake = totalStake.add(msg.value);
            emit deposit(msg.sender, msg.value);
            staking.delegator_bond_more(target, msg.value);
        }
        else if  (currentState == daoState.COLLECTING ){
            memberStakes[msg.sender] = memberStakes[msg.sender].add(msg.value);
            totalStake = totalStake.add(msg.value);
            emit deposit(msg.sender, msg.value);
            if(totalStake < minDelegationStk){
                return;
            } else {
                //initialiate the delegation and change the state          
                staking.delegate(target, address(this).balance, staking.candidate_delegation_count(target), staking.delegator_delegation_count(address(this)));
                currentState = daoState.STAKING;
                reset_vote();
            }
        }
        else {
            revert("The DAO is not accepting new stakes in the current state.");
        }
    }

    // Function for a user to withdraw their stake
    function withdraw(address payable account) public {
        require(currentState != daoState.STAKING, "The DAO is not in the correct state to withdraw.");
        if (currentState == daoState.REVOKING) {
            bool result = execute_revoke();
            require(result, "Schedule revoke delay is not finished yet.");
        }
        if (currentState == daoState.REVOKED || currentState == daoState.COLLECTING) {
            //Sanity checks
            if(staking.is_delegator(address(this))){
                 revert("The DAO is in an inconsistent state.");
            }
            require(totalStake!=0, "Cannot divide by zero.");
            //Calculate the withdrawal amount including staking rewards
            uint amount = address(this)
                .balance
                .mul(memberStakes[msg.sender])
                .div(totalStake);
            require(check_free_balance() >= amount, "Not enough free balance for withdrawal.");
            Address.sendValue(account, amount);
            totalStake = totalStake.sub(memberStakes[msg.sender]);
            memberStakes[msg.sender] = 0;
            emit withdrawal(msg.sender, account, amount);
        }
    }

    function indexOf(address[] memory arr, address searchFor) private pure returns(int) {
        for (uint i = 0; i < arr.length; i++) {
            if (arr[i] == searchFor) {
                return int(i);
            }
        }
        return int(-1); // not found
    }    

    function vote_revoke() public {
        require(currentState == daoState.REVOKING, "msg: state err");
        require(indexOf(revokeVoter, msg.sender) < 0, "msg: Voted");
        require(memberStakes[msg.sender] > 0, "msg: zero token");

        revokeVoter.push(msg.sender);
        totalRevokeVote = totalRevokeVote.add(memberStakes[msg.sender]);

        if (totalRevokeVote > totalStake.sub(2)){
            revokeState = true;
            schedule_revoke();
            revokeState = false;
            delete revokeVoter;
            totalRevokeVote = 0;               
        }
    }

    // Schedule revoke, admin only
    function schedule_revoke() internal {
        require(currentState == daoState.STAKING, "The DAO is not in the correct state to schedule a revoke.");
        staking.schedule_revoke_delegation(target);
        currentState = daoState.REVOKING;      
    }
    
    // Try to execute the revoke, returns true if it succeeds, false if it doesn't
    function execute_revoke() internal returns(bool) {
        require(currentState == daoState.REVOKING, "The DAO is not in the correct state to execute a revoke.");
        staking.execute_delegation_request(address(this), target);
        if (staking.is_delegator(address(this))){
            return false;
        } else {
            currentState = daoState.REVOKED;
            return true;
        }
    }

    // Check how much free balance the DAO currently has. It should be the staking rewards if the DAO state is anything other than REVOKED or COLLECTING. 
    function check_free_balance() public view returns(uint256) {
        return address(this).balance;
    }
    
    // // Change the collator target, admin only
    // function change_target(address newCollator) public onlyGovernance {
    //     require(currentState == daoState.REVOKED || currentState == daoState.COLLECTING, "The DAO is not in the correct state to change staking target.");
    //     target = newCollator;
    // }


    function vote_reset() public {
        require(currentState == daoState.REVOKED || currentState == daoState.COLLECTING, "The DAO is not in the correct state to change staking target.");
        require(indexOf(resetVoter, msg.sender) < 0, "msg: Voted");
        require(memberStakes[msg.sender] > 0, "msg: zero token");
        resetVoter.push(msg.sender);
        totalResetVote = totalResetVote.add(memberStakes[msg.sender]);

        if (totalResetVote > totalStake.sub(2)){
            resetState = true;
            reset_dao();
            resetState = false;
            delete resetVoter;
            totalResetVote = 0;  
        }
    }    

    // Reset the DAO state back to COLLECTING, admin only
    function reset_dao() internal {
        currentState = daoState.COLLECTING;
    }

    function reset_vote() internal {
        resetState = false;
        delete resetVoter;
        totalResetVote = 0;  
        revokeState = false;
        delete revokeVoter;
        totalRevokeVote = 0;                          
    }

}
