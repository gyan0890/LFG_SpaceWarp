// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.13;

//import {StdStorage} from "../lib/forge-std/src/Components.sol";
//import {specific_authenticate_message_params_parse, specific_deal_proposal_cbor_parse} from "./CBORParse.sol";

import "https://github.com/foundry-rs/forge-std/blob/5bafa16b4a6aa67c503d96294be846a22a6f6efb/src/StdStorage.sol";
import "https://github.com/lotus-web3/client-contract/blob/main/src/CBORParse.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";

import "@openzeppelin/contracts/utils/Counters.sol";

contract MockMarket {

    LFGDataDAO client;

    constructor(address _client) {
        client = LFGDataDAO(_client);
    }

    function publish_deal(bytes calldata raw_auth_params, uint256 proposalID) public {
        // calls standard filecoin receiver on message authentication api method number
        client.handle_filecoin_method(0, 2643134072, raw_auth_params, proposalID);
    }

}

contract LFGNft is ERC721URIStorage {
    using Counters for Counters.Counter;
    Counters.Counter private _tokenIds;

    constructor(string memory tokenName, string memory symbol) ERC721(tokenName, symbol) {

    }

    function _baseURI() internal pure override returns (string memory) {
        return "ipfs://";
    }

    function mintToken(address owner, string memory metadataURI)
    public
    {
        _tokenIds.increment();

        uint256 id = _tokenIds.current();
        _safeMint(owner, id);
        _setTokenURI(id, metadataURI);
    }

}

contract LFGDataDAO is LFGNft{

    uint64 constant public AUTHORIZE_MESSAGE_METHOD_NUM = 2643134072; 

    mapping(bytes => bool) public cidSet;
    mapping(bytes => uint) public cidSizes;
    mapping(bytes => mapping(bytes => bool)) public cidProviders;

    uint256 public courseCount;
    LFGNft nftAddress;
    address nftOwner;
    address contractOwner;
    string metadataURI; //https://ipfs.io/ipfs/QmQisurgqAnTr42C8LnxJsVpKNZcM8ykzxqRGTq1DaW1Zw

    struct Course {
        uint256 courseID;
        string courseTitle;
        uint256 duration; //In minutes
        string courseTopic;
        address storageProvider;
        bytes cidRaw;
        uint numAssets;
        uint256 upVoteCount;
        uint256 downVoteCount;
        uint256 proposedAt;
        uint256 proposalExpireAt;
    }

    mapping(uint256 => Course) public courses;
    mapping(address => uint256[]) public userCourseMap;
    mapping(address => mapping(uint256 => bool)) public hasVotedForCourse;
    mapping(uint256 => bytes) public courseCIDMap;
    mapping(address => bool) public userDatabase;

    modifier onlyOwner() {
        require(msg.sender == contractOwner, "Only contract owner can call this function");
        _;
    }

    constructor(string memory tokenName, string memory symbol, string memory _metadataURI) LFGNft(tokenName, symbol) {
        contractOwner = msg.sender;
        metadataURI = _metadataURI;
    }

    function setNFTContractAddress(address _nftAddress) public onlyOwner{
        nftAddress = LFGNft(_nftAddress);
    }

    function getSP(uint256 courseID) view internal returns(address) {
        return courses[courseID].storageProvider;
    }

    function isCallerSP(uint256 courseID) view internal returns(bool) {
       return getSP(courseID) == msg.sender;
    }

    function isVotingOn(uint256 courseID) view internal returns(bool) {
       return courses[courseID].proposalExpireAt > block.timestamp;
    }

    //Upload a new course - all the course metadata is stored on-chain for now. Will move to dec-storage later
    function uploadCourse(bytes calldata cidraw, uint size, 
        string memory courseTitle, uint256 courseDuration, string memory courseTopic) public returns(uint256){
        courseCount = courseCount + 1;
        Course memory course = Course(courseCount, courseTitle, courseDuration, courseTopic, 
            msg.sender, cidraw, size, 0, 0, block.timestamp, block.timestamp + 180 minutes);
        courses[courseCount] = course;
        courseCIDMap[courseCount] = cidraw;
        cidSet[cidraw] = true;
        cidSizes[cidraw] = size;
        return courseCount;
    }

    function enrollIntoCourse(uint256 courseID) public {
        //require(policyOK(courseID), "This course has not been published yet on the platform");
        require(courses[courseID].courseID != 0, "Course ID does not exist");
        if(userDatabase[msg.sender] == false) {
            userDatabase[msg.sender] == true;
            //Mint a new NFT to every first time user
            nftAddress.mintToken(msg.sender, metadataURI);
        }
        userCourseMap[msg.sender].push(courseID);
    }

    function getCoursesForAddress(address user) public view returns(uint256[] memory){
        return userCourseMap[user];
    }

    function getMaxCourseCount() public view returns(uint) {
        return courseCount;
    }

    function getCIDFromCourseID(uint256 courseID) public view returns(bytes memory) {
        return courseCIDMap[courseID];
    }

    function getCourseDetailsFromID(uint256 courseID) public view returns(Course memory) {
        return courses[courseID];
    }

    function upvoteCIDCourse(uint256 courseID) public {
        require(!isCallerSP(courseID), "Storage Provider cannot vote his own proposal");
        require(!hasVotedForCourse[msg.sender][courseID], "Already Voted");
        require(isVotingOn(courseID), "Voting Period Finished");
        courses[courseID].upVoteCount = courses[courseID].upVoteCount + 1;
        hasVotedForCourse[msg.sender][courseID] = true;
    }

    function downvoteCIDCourse(uint256 courseID) public {
        require(!isCallerSP(courseID), "Storage Provider cannot vote his own proposal");
        require(!hasVotedForCourse[msg.sender][courseID], "Already Voted");
        require(isVotingOn(courseID), "Voting Period Finished");
        courses[courseID].downVoteCount = courses[courseID].downVoteCount + 1;
        hasVotedForCourse[msg.sender][courseID] = true;
    }
     
    function policyOK(uint256 courseID) internal view returns (bool) {
        //require(proposals[proposalID].proposalExpireAt > block.timestamp, "Voting in On");
        return courses[courseID].upVoteCount > courses[courseID].downVoteCount;
    }

    function authorizeData(uint256 courseID, bytes calldata cidraw, bytes calldata provider, uint size) public {
        require(cidSet[cidraw], "CID must be added before authorizing");
        require(cidSizes[cidraw] == size, "Data size must match expected");
        require(policyOK(courseID), "Deal failed policy check: Was the CID proposal Passed?");
        cidProviders[cidraw][provider] = true;
    }

    function handle_filecoin_method(uint64, uint64 method, bytes calldata params, uint256 courseID) public {
        // dispatch methods
        if (method == AUTHORIZE_MESSAGE_METHOD_NUM) {
            bytes calldata deal_proposal_cbor_bytes = specific_authenticate_message_params_parse(params);
            (bytes calldata cidraw, bytes calldata provider, uint size) = specific_deal_proposal_cbor_parse(deal_proposal_cbor_bytes);
            cidraw = bytes(bytes(cidraw));
            authorizeData(courseID, cidraw, provider, size);
        } else {
            revert("The Filecoin method that was called is not handled");
        }
    }

}


contract LFG_NFT is ERC721URIStorage {
    using Counters for Counters.Counter;
    Counters.Counter private _tokenIds;

    constructor(string memory tokenName, string memory symbol) ERC721(tokenName, symbol) {

    }

    function _baseURI() internal pure override returns (string memory) {
        return "ipfs://";
    }

    function mintToken(address owner, string memory metadataURI)
    public
    {
        _tokenIds.increment();

        uint256 id = _tokenIds.current();
        _safeMint(owner, id);
        _setTokenURI(id, metadataURI);
    }

    function getNumTokens() public view returns(uint256) {
        return _tokenIds.current();
    }
}
