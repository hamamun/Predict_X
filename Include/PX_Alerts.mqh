#ifndef __PX_ALERTS_MQH__
#define __PX_ALERTS_MQH__

// Phase 4 alerts only.
// PREDICT-X chart controls were removed by user decision.

void PX4_SendAlert(bool usePush,bool usePopup,bool useSound,string message,string soundFile="alert.wav")
{
   string msg="PREDICT-X: "+message;
   if(usePopup) Alert(msg);
   if(usePush)  SendNotification(msg);
   if(useSound) PlaySound(soundFile);
   Print(msg);
}

void PX4_DeleteObjects()
{
   // Legacy cleanup only: removes old PX4 control objects if they exist on chart.
   for(int i=ObjectsTotal(0)-1;i>=0;i--)
   {
      string name=ObjectName(0,i);
      if(StringFind(name,"PX4_")==0) ObjectDelete(0,name);
   }
}

#endif
