package com.genymobile.scrcpy.control;

import android.net.LocalSocket;

import java.io.IOException;

public final class ControlChannel {

    private final ControlMessageReader reader;
    private final DeviceMessageWriter writer;

    public ControlChannel(LocalSocket controlSocket) throws IOException {
        this(controlSocket.getInputStream(), controlSocket.getOutputStream());
    }

    public ControlChannel(java.io.InputStream input, java.io.OutputStream output) {
        reader = new ControlMessageReader(input);
        writer = new DeviceMessageWriter(output);
    }

    public ControlMessage recv() throws IOException {
        return reader.read();
    }

    public void send(DeviceMessage msg) throws IOException {
        writer.write(msg);
    }
}
