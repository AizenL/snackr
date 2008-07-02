/*
	Copyright (c) 2008 Narciso Jaramillo
	All rights reserved.

	Redistribution and use in source and binary forms, with or without 
	modification, are permitted provided that the following conditions are met:

    * Redistributions of source code must retain the above copyright notice, 
      this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above copyright 
      notice, this list of conditions and the following disclaimer in the 
      documentation and/or other materials provided with the distribution.
    * Neither the name of Narciso Jaramillo nor the names of other 
      contributors may be used to endorse or promote products derived from 
      this software without specific prior written permission.

	THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" 
	AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE 
	IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE 
	DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE 
	FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL 
	DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR 
	SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER 
	CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
	OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE 
	USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*/

package model.feeds.readers
{
	import flash.data.SQLConnection;
	
	import model.feeds.Feed;
	import model.feeds.FeedItem;
	import model.feeds.FeedModel;
	
	import mx.collections.ArrayCollection;

	/**
	 *	Provides common functionality used by many feed reader synchronizers.
	 *	FeedReaderSynchronizerBase is not a complete implementation of IFeedReaderSynchronizer
	 *	itself - see its subclasses for implementations for specific reader programs.
	 *	@author Rob Adams
	*/
	public class FeedReaderSynchronizerBase implements IFeedReaderSynchronizer
	{
		public static const SNACKR_CLIENT_ID: String = "Snackr";
		
		private static const MERGE: int = 0;
		private static const SET: int = 1;
		
		private var _pendingOperationModel: PendingOperationModel;
		private var _feedModel: FeedModel;
		
		public function FeedReaderSynchronizerBase(sqlConnection: SQLConnection, feedModel: FeedModel) {
			_pendingOperationModel = new PendingOperationModel(sqlConnection);
			_feedModel = feedModel;
		}
		
		public function synchronizeAll(): void {
			//get feed list from reader
			getFeeds(function retrieveFeeds(feedsList: ArrayCollection) : void {
				if(feedsList != null) {
					//TODO: calls to _feedModel will trigger a call back to the reader's addFeed, deleteFeed, and
					//setItemRead methods - unnecessarily in this case since the sync method will always
					//be operating on feeds and items that are properly set on the server. Ideally we'd avoid
					//this unnecessary network call, but as all the solutions seem to add complexity I decided
					//to wait and see if it becomes a problem first.
					
					//for each feed in reader, if feed doesnt already exist AND its not in the ops list for removal, add it
					for each (var feedURL: String in feedsList) {
						if(!_pendingOperationModel.isMarkedForDelete(feedURL))
							_feedModel.addFeedURL(feedURL, true, false);
					}
					//for each feed in snackr, if feed isn't in the reader AND its not in the ops list for addition, remove it
					for each (var feed: Feed in _feedModel.feeds) {
						if(!(isInReaderFeedsList(feed.url, feedsList) || _pendingOperationModel.isMarkedForAdd(feed.url)))
							_feedModel.deleteFeed(feed, false);
					}
					//get read items list from server
					getReadItems(function retrieveReadItems(itemsList: ArrayCollection) : void {
						//mark all items read in snackr
						for each (var item: Object in itemsList) {
							_feedModel.setItemReadByIDs(item.itemURL, item.guid, true, false);
						}
						var pendingOps: ArrayCollection = _pendingOperationModel.operations;
						//clear pending operations from model
						_pendingOperationModel.clearOperations();
						//retry all pending operations (if they fail they'll automatically wind up back
						//in the pendingops table)
						for each (var pendingOp:PendingOperation in pendingOps) {
							switch(pendingOp.opCode) {
								case PendingOperation.ADD_FEED_OPCODE:
									addFeed(pendingOp.feedURL);
									break;
								case PendingOperation.DELETE_FEED_OPCODE:
									deleteFeed(pendingOp.feedURL);
									break;
								case PendingOperation.MARK_READ_OPCODE:
									var itemInfo: Object = new Object();
									itemInfo.link = pendingOp.itemURL;
									var feedItem: FeedItem = new FeedItem(itemInfo);
									var newFeed : Feed = new Feed(null, null);
									newFeed.url = pendingOp.feedURL;
									feedItem.feed = newFeed;
									setItemRead(feedItem);
									break;
							}
						}
					});
				}
			});
		}
		
		private function isInReaderFeedsList(feedURL: String, feedsList: ArrayCollection) : Boolean {
			for each (var readerFeed: String in feedsList) {
				if(readerFeed == feedURL)
					return true;
			}
			return false;
		}
		
		protected function markFeedForAdd(url: String) : void {
			var pendingOp: PendingOperation = new PendingOperation(PendingOperation.ADD_FEED_OPCODE, url);
			_pendingOperationModel.addOperation(pendingOp);
		}
		
		protected function markFeedForDelete(url: String) : void {
			var pendingOp: PendingOperation = new PendingOperation(PendingOperation.DELETE_FEED_OPCODE, url);
			_pendingOperationModel.addOperation(pendingOp);
		}
		
		protected function markItemForReadStatusAssignment(feedURL: String, itemURL: String) : void {
			var pendingOp: PendingOperation = new PendingOperation(PendingOperation.MARK_READ_OPCODE, feedURL, itemURL);
			_pendingOperationModel.addOperation(pendingOp);
		}
		
		public function mergeFeedLists(): void {
			mergeOrSetFeeds(_feedModel.feeds, MERGE);
		}
		
		private function mergeOrSetFeeds(feedList: ArrayCollection, opCode: int) : void {
			//retrieve feed list from the reader
			getFeeds(function retrieveFeeds(readerFeedsList: ArrayCollection) : void {
				var snackrFeedsList: ArrayCollection = new ArrayCollection;
				//copy the array so we don't mess up FeedModel's copy
				for each(var feed: Feed in feedList) {
					snackrFeedsList.addItem(feed);
				}
				for each(var feedURL: String in readerFeedsList) {
					var inSnackr: Boolean = false;
					//for each feed in the reader, if its not in snackr, add it to snackr if merging, 
					//remove it from the reader if setting
					for each (var snackrFeed: Feed in snackrFeedsList) {
						if(snackrFeed.url == feedURL) {
							inSnackr = true;
							//if it is in snackr, remove it from the Snackr list
							snackrFeedsList.removeItemAt(snackrFeedsList.getItemIndex(snackrFeed));
							break;
						}
					}
					if(!inSnackr) {
						if(opCode == MERGE)
							_feedModel.addFeedURL(feedURL, true, false);
						else if(opCode == SET)
							deleteFeed(feedURL);
					}
				}
				//for all remaining feeds in the snackr list, add them to the reader
				for each(var feedToAdd: Feed in snackrFeedsList) {
					addFeed(feedToAdd.url);
				}
			});
			//TODO: synchronize the read items as well at this point
			getReadItems(function retrieveReadItemsForAssignment(itemsList: ArrayCollection) : void {
				var itemsInSnackrByLink : Object = new Object();
				var itemsInSnackrByGuid : Object = new Object();
				//mark all items read in snackr
				for each (var item: Object in itemsList) {
					if(_feedModel.getItemByIDs(item.itemURL, item.guid) != null) {
						_feedModel.setItemReadByIDs(item.itemURL, item.guid, true, false);
						itemsInSnackrByLink[item.itemURL] = item;
						itemsInSnackrByGuid[item.guid] = item;
					}
				}
				for each (var feedItem: FeedItem in _feedModel.getReadItems()) {
					if((itemsInSnackrByLink[feedItem.link] == null) && (itemsInSnackrByGuid[feedItem.guid] == null)) {
						setItemRead(feedItem);
					}
				}
			});
		}
			
		public function setFeedList(newFeedList: ArrayCollection): void {
			mergeOrSetFeeds(newFeedList, SET);
		}
		
		public function getFeeds(callback: Function): void
		{
			//implemented by subclasses
		}
		
		public function addFeed(feedURL:String): void
		{
			//implemented by subclasses
		}
		
		public function deleteFeed(feedURL:String): void
		{
			//implemented by subclasses
		}
		
		public function getReadItems(callback: Function): void
		{
			//implemented by subclasses
		}
		
		public function setItemRead(item:FeedItem): void
		{
			//implemented by subclasses
		}
		
	}
}