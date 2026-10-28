package com.genymobile.scrcpy.control;

/** Relative scroll playback; native trackpad momentum is already in the deltas. */
public final class WheelScroll {
    public interface Sink { void touch(int action, int x, int y); }
    private final int width, height, anchorX, anchorY;
    private final Sink sink;
    private double x, y, pendingX, pendingY;
    private long lastTick, lastCommand, lastMove;
    private boolean active;

    public WheelScroll(int width, int height, int anchorX, int anchorY, Sink sink) {
        this.width = width; this.height = height;
        this.anchorX = Math.max(1, Math.min(width-2, anchorX));
        this.anchorY = Math.max(1, Math.min(height-2, anchorY));
        this.sink = sink;
    }
    public boolean isActive() { return active; }
    public void add(int dx, int dy, long now) {
        if (width < 4 || height < 4 || (dx == 0 && dy == 0)) return;
        if (!active) {
            active = true; x = anchorX; y = anchorY; lastTick = lastMove = now;
            sink.touch(0, (int)x, (int)y);
        }
        pendingX += dx; pendingY += dy; lastCommand = now;
    }
    public void tick(long now) {
        if (!active) return;
        double elapsed = Math.max(0, Math.min(32, now-lastTick)); lastTick = now;
        double fraction = 1-Math.exp(-elapsed/40.0);
        double dx = Math.abs(pendingX) < 0.25 ? pendingX : pendingX*fraction;
        double dy = Math.abs(pendingY) < 0.25 ? pendingY : pendingY*fraction;
        double scale = Math.min(1, Math.min(width*0.2/Math.max(0.001,Math.abs(dx)), height*0.2/Math.max(0.001,Math.abs(dy))));
        dx *= scale; dy *= scale;
        if (Math.abs(dx) > 0.001 || Math.abs(dy) > 0.001) {
            if (x+dx < 1 || x+dx > width-2 || y+dy < 1 || y+dy > height-2) {
                // Commit the completed drag before re-anchoring. CANCEL makes
                // pagers roll back the page transition instead of completing it.
                sink.touch(1, (int)Math.round(x), (int)Math.round(y));
                // Stay as close to the cursor as possible while leaving room
                // for this step, including when the cursor is at the border.
                x = Math.max(Math.ceil(1-Math.min(0,dx)), Math.min(Math.floor(width-2-Math.max(0,dx)), anchorX));
                y = Math.max(Math.ceil(1-Math.min(0,dy)), Math.min(Math.floor(height-2-Math.max(0,dy)), anchorY));
                sink.touch(0, (int)x, (int)y);
            }
            // Cursor anchors may be close to an edge. Consume only the part
            // that fits and retain the remaining distance for the next tick.
            dx = Math.max(1-x, Math.min(width-2-x, dx));
            dy = Math.max(1-y, Math.min(height-2-y, dy));
            int oldX = (int)Math.round(x), oldY = (int)Math.round(y);
            x += dx; y += dy; pendingX -= dx; pendingY -= dy;
            int nextX = (int)Math.round(x), nextY = (int)Math.round(y);
            if (oldX != nextX || oldY != nextY) { sink.touch(2,nextX,nextY); lastMove = now; }
        }
        // Let the final position settle so a wheel burst does not add an
        // unintended touchscreen fling after the wheel itself has stopped.
        if (Math.abs(pendingX) < 0.001 && Math.abs(pendingY) < 0.001 && now-lastCommand >= 80 && now-lastMove >= 50) finish();
    }
    private void finish() {
        if (active) sink.touch(1,(int)Math.round(x),(int)Math.round(y));
        active = false; pendingX = pendingY = 0;
    }
    public void cancel() {
        // Reserve CANCEL for actual interruptions, never successful scrolling.
        if (active) sink.touch(3,(int)Math.round(x),(int)Math.round(y));
        active = false; pendingX = pendingY = 0;
    }
}
