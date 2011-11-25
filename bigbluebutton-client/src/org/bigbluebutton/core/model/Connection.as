/**
* BigBlueButton open source conferencing system - http://www.bigbluebutton.org/
*
* Copyright (c) 2010 BigBlueButton Inc. and by respective authors (see below).
*
* This program is free software; you can redistribute it and/or modify it under the
* terms of the GNU Lesser General Public License as published by the Free Software
* Foundation; either version 2.1 of the License, or (at your option) any later
* version.
*
* BigBlueButton is distributed in the hope that it will be useful, but WITHOUT ANY
* WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
* PARTICULAR PURPOSE. See the GNU Lesser General Public License for more details.
*
* You should have received a copy of the GNU Lesser General Public License along
* with BigBlueButton; if not, see <http://www.gnu.org/licenses/>.
* 
*/
package org.bigbluebutton.core.model {
	import com.asfusion.mate.events.Dispatcher;
	
	import flash.events.*;
	import flash.net.NetConnection;
	import flash.net.Responder;
	import flash.utils.Timer;
	
	import org.bigbluebutton.common.LogUtil;
	import org.bigbluebutton.core.events.ConnectionFailedEvent;
	import org.bigbluebutton.core.events.UsersConnectionEvent;
	import org.bigbluebutton.main.model.ConferenceParameters;
		
	public class Connection {
		private var alias:String = "unknown";
		private var _nc:NetConnection;	
		private var connectionId:Number;
		private var connected:Boolean = false;
		private var fullUri:String;
		private var _userid:Number = -1;
		private var _role:String = "unknown";
		private var _conferenceParameters:ConferenceParameters;
		private var autoReconnect:Boolean = false;
		private var numRetries:int = 1;
		
		// These two are just placeholders. We'll get this from the server later and
		// then pass to other modules.
		private var _authToken:String = "AUTHORIZED";
		private var _room:String;
		private var tried_tunneling:Boolean = false;
		private var logoutOnUserCommand:Boolean = false;
		private var backoff:Number = 2000;
		
		private var dispatcher:Dispatcher;
				
		public function Connection(alias:String):void {
			this.alias = alias;
			dispatcher = new Dispatcher();
			
			_nc = new NetConnection();				
			_nc.client = this;
			_nc.addEventListener(NetStatusEvent.NET_STATUS, netStatus);
			_nc.addEventListener(AsyncErrorEvent.ASYNC_ERROR, netASyncError);
			_nc.addEventListener(SecurityErrorEvent.SECURITY_ERROR, netSecurityError);
			_nc.addEventListener(IOErrorEvent.IO_ERROR, netIOError);
		}
		
		public function setAutoReconnect(reconnect:Boolean):void {
			autoReconnect = reconnect;
		}
		
		public function setNumRetries(retries:int):void {
			numRetries = retries;
		}
		
		public function get connection():NetConnection {
			return _nc;
		}
		
		public function handleMessage(messageName:String, param:Object):void {
			LogUtil.debug("*****BBBBOOOOYEAHHHHH!!!! " + messageName);
		}
		
		/**
		 * Connect to the server.
		 * uri: The uri to the conference application.
		 * username: Fullname of the participant.
		 * role: MODERATOR/VIEWER
		 * conference: The conference room
		 * mode: LIVE/PLAYBACK - Live:when used to collaborate, Playback:when being used to playback a recorded conference.
		 * room: Need the room number when playing back a recorded conference. When LIVE, the room is taken from the URI.
		 */
		public function connect(uri:String, params:ConferenceParameters, tunnel:Boolean = false):void {	
			_conferenceParameters = params;			
			tried_tunneling = tunnel;			
			fullUri = uri;
			
			realConnect(fullUri, _conferenceParameters.username, _conferenceParameters.role, _conferenceParameters.conference, 
							_conferenceParameters.room, _conferenceParameters.voicebridge, 
							_conferenceParameters.record, _conferenceParameters.externUserID);			
		}
		
		private function realConnect(uri:String, username:String, role:String, conference:String, 
									 room:String, voicebridge:String, record:Boolean, externUserID:String):void {
			try {	
				LogUtil.debug(alias + "::Connecting to " + uri + " [" + username + "," + role + "," +  conference + "," + record + "," + room + "]");	
				_nc.connect(uri, username, role, conference, room, voicebridge, record, externUserID);			
			} catch(e:ArgumentError) {
				// Invalid parameters.
				switch (e.errorID) {
					case 2004 :						
						LogUtil.debug("Error! Invalid server location: " + uri);											   
						break;						
					default :
						LogUtil.debug("UNKNOWN Error! Invalid server location: " + uri);
						break;
				}
			}
		}
		
		public function disconnect(logoutOnUserCommand:Boolean):void {
			this.logoutOnUserCommand = logoutOnUserCommand;
			_nc.close();
		}
					
		protected function netStatus(event:NetStatusEvent):void {
			handleResult(event);
		}
		
		public function handleResult(event:Object):void {
			var info:Object = event.info;
			var statusCode:String = info.code;

			switch (statusCode) {
				case "NetConnection.Connect.Success":
					LogUtil.debug(alias + ":Connection to viewers application succeeded.");
					_nc.call("getMyUserId",// Remote function name
							new Responder(
	        					// result - On successful result
								function(result:Object):void { 
									LogUtil.debug("Successful result: " + result); 
									sendConnectionSuccessEvent(result);
								},	
								// status - On error occurred
								function(status:Object):void { 
									LogUtil.error("Error occurred:"); 
									for (var x:Object in status) { 
										LogUtil.error(x + " : " + status[x]); 
									} 
								}
							)//new Responder
					); //_netConnection.call			
					break;
			
				case "NetConnection.Connect.Failed":					
					if (tried_tunneling) {
						LogUtil.debug(alias + ":Connection to viewers application failed...even when tunneling");
						sendConnectionFailedEvent(ConnectionFailedEvent.CONNECTION_FAILED);
					} else {
						disconnect(false);
						LogUtil.debug(alias + ":Connection to viewers application failed...try tunneling");
						var rtmptRetryTimer:Timer = new Timer(1000, 1);
            			rtmptRetryTimer.addEventListener("timer", rtmptRetryTimerHandler);
            			rtmptRetryTimer.start();						
					}									
					break;
					
				case "NetConnection.Connect.Closed":	
					LogUtil.debug(alias + ":Connection to viewers application closed");					
					sendConnectionFailedEvent(ConnectionFailedEvent.CONNECTION_CLOSED);								
					break;
					
				case "NetConnection.Connect.InvalidApp":	
					LogUtil.debug(alias + ":viewers application not found on server");			
					sendConnectionFailedEvent(ConnectionFailedEvent.INVALID_APP);				
					break;
					
				case "NetConnection.Connect.AppShutDown":
					LogUtil.debug(alias + ":viewers application has been shutdown");
					sendConnectionFailedEvent(ConnectionFailedEvent.APP_SHUTDOWN);	
					break;
					
				case "NetConnection.Connect.Rejected":
					LogUtil.debug(alias + ":Connection to the server rejected. Uri: " + fullUri 
						+ ". Check if the red5 specified in the uri exists and is running" );
					sendConnectionFailedEvent(ConnectionFailedEvent.CONNECTION_REJECTED);		
					break;
					
				default :
				   LogUtil.debug(alias + ":Default status to the viewers application" );
				   sendConnectionFailedEvent(ConnectionFailedEvent.UNKNOWN_REASON);
				   break;
			}
		}
		
		private function rtmptRetryTimerHandler(event:TimerEvent):void {
            LogUtil.debug(alias + "rtmptRetryTimerHandler: " + event);
            connect(fullUri, _conferenceParameters, true);
        }
			
		protected function netSecurityError(event:SecurityErrorEvent):void {
			LogUtil.debug("Security error - " + event.text);
			sendConnectionFailedEvent(ConnectionFailedEvent.UNKNOWN_REASON);
		}
		
		protected function netIOError(event:IOErrorEvent):void {
			LogUtil.debug("Input/output error - " + event.text);
			sendConnectionFailedEvent(ConnectionFailedEvent.UNKNOWN_REASON);
		}
			
		protected function netASyncError(event:AsyncErrorEvent):void {
			LogUtil.debug("Asynchronous code error - " + event.error );
			sendConnectionFailedEvent(ConnectionFailedEvent.UNKNOWN_REASON);
		}	

		/**
	 	*  Callback from server
	 	*/
		public function setUserId(id:Number, role:String):String {
			LogUtil.debug( "ViewersNetDelegate::setConnectionId: id=[" + id + "," + role + "]");
			if (isNaN(id)) return "FAILED";
			
			// We should be receiving authToken and room from the server here.
			_userid = id;								
			return "OK";
		}
		
		private function sendConnectionSuccessEvent(userid:Object):void{
			var useridString:String = userid as String;
			var n:int = parseInt(useridString);
			
			var e:UsersConnectionEvent = new UsersConnectionEvent(UsersConnectionEvent.CONNECTION_SUCCESS);
			e.connection = _nc;
			e.userid = n;
			dispatcher.dispatchEvent(e);
			
			backoff = 2000;
		}
		
		private function sendConnectionFailedEvent(reason:String):void{
			if (this.logoutOnUserCommand){
				sendUserLoggedOutEvent();
				return;
			}
			
			var e:ConnectionFailedEvent = new ConnectionFailedEvent(reason);
			dispatcher.dispatchEvent(e);
		}
		
		private function sendUserLoggedOutEvent():void{
			var e:ConnectionFailedEvent = new ConnectionFailedEvent(ConnectionFailedEvent.USER_LOGGED_OUT);
			dispatcher.dispatchEvent(e);
		}
		
		private function attemptReconnect(backoff:Number):void{
			var retryTimer:Timer = new Timer(backoff, 1);
			retryTimer.addEventListener(TimerEvent.TIMER, function():void{
				connect(fullUri, _conferenceParameters, tried_tunneling);
			});
			retryTimer.start();
			if (this.backoff < 16000) this.backoff = backoff *2;
		}
		
		public function onBWCheck(... rest):Number { 
			return 0; 
		} 
		
		public function onBWDone(... rest):void { 
			var p_bw:Number; 
			if (rest.length > 0) p_bw = rest[0]; 
			// your application should do something here 
			// when the bandwidth check is complete 
			trace("bandwidth = " + p_bw + " Kbps."); 
		}
	}
}
