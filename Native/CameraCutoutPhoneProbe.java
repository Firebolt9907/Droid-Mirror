package com.genymobile.scrcpy.control;

import com.genymobile.scrcpy.Options;
import com.genymobile.scrcpy.Workarounds;
import com.genymobile.scrcpy.display.DisplayInfo;
import com.genymobile.scrcpy.model.Size;
import com.genymobile.scrcpy.wrappers.ServiceManager;
import android.graphics.Rect;
import android.os.Looper;
import java.io.ByteArrayOutputStream;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.List;
import java.util.concurrent.BlockingQueue;

/** Read-only geometry/protocol probe; never injects events or changes display settings. */
public final class CameraCutoutPhoneProbe {
    public static void main(String[] args) throws Exception {
        Looper.prepareMainLooper();
        Workarounds.apply();
        DisplayInfo display = ServiceManager.getDisplayManager().getDisplayInfo(0);
        List<Rect> rects = ServiceManager.getDisplayManager().getCameraCutoutBounds(0);
        if (rects.isEmpty()) throw new AssertionError("Expected a cutout on the connected test phone");
        Size physical = display.getSize();
        Size video = new Size(physical.getWidth()/2,physical.getHeight()/2);
        PositionMapper mapper = PositionMapper.create(video,null,physical);
        for (Rect rect : rects) {
            Rect scaled = mapper.mapDeviceRect(rect);
            if (Math.abs(scaled.left*2-rect.left)>1 || Math.abs(scaled.top*2-rect.top)>1
                    || Math.abs(scaled.right*2-rect.right)>1 || Math.abs(scaled.bottom*2-rect.bottom)>1) {
                throw new AssertionError("Incorrect inverse video mapping");
            }
            System.out.println("Android camera bounds="+rect+", half-resolution bounds="+scaled);
        }
        Options options = Options.parse("5.0","clipboard_autosync=false","power_on=false","cleanup=false");
        Controller controller = new Controller(null,null,options);
        controller.onNewVirtualDisplay(0,mapper);
        Method send = Controller.class.getDeclaredMethod("sendCameraCutout"); send.setAccessible(true); send.invoke(controller);
        Field senderField = Controller.class.getDeclaredField("sender"); senderField.setAccessible(true);
        Object sender = senderField.get(controller);
        Field queueField = DeviceMessageSender.class.getDeclaredField("queue"); queueField.setAccessible(true);
        DeviceMessage message=(DeviceMessage)((BlockingQueue<?>)queueField.get(sender)).poll();
        if(message==null || message.getType()!=3) throw new AssertionError("Missing cutout response");
        ByteArrayOutputStream bytes=new ByteArrayOutputStream(); new DeviceMessageWriter(bytes).write(message);
        byte[] wire=bytes.toByteArray();
        if(wire.length!=6+16*rects.size() || wire[0]!=3 || wire[5]!=rects.size()) throw new AssertionError("Invalid cutout wire format");
        controller.stop();
        System.out.println("PASS: live camera outline bounds, inverse video mapping, controller metadata and serialized response ("+wire.length+" bytes)");
    }
}
