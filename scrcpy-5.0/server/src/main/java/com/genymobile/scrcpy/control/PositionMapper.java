package com.genymobile.scrcpy.control;

import android.graphics.Rect;

import com.genymobile.scrcpy.model.Point;
import com.genymobile.scrcpy.model.Position;
import com.genymobile.scrcpy.model.Size;
import com.genymobile.scrcpy.util.AffineMatrix;

public final class PositionMapper {

    private final Size videoSize;
    private final AffineMatrix videoToDeviceMatrix;

    public PositionMapper(Size videoSize, AffineMatrix videoToDeviceMatrix) {
        this.videoSize = videoSize;
        this.videoToDeviceMatrix = videoToDeviceMatrix;
    }

    public static PositionMapper create(Size videoSize, AffineMatrix filterTransform, Size targetSize) {
        boolean convertToPixels = !videoSize.equals(targetSize) || filterTransform != null;
        AffineMatrix transform = filterTransform;
        if (convertToPixels) {
            AffineMatrix inputTransform = AffineMatrix.ndcFromPixels(videoSize);
            AffineMatrix outputTransform = AffineMatrix.ndcToPixels(targetSize);
            transform = outputTransform.multiply(transform).multiply(inputTransform);
        }

        return new PositionMapper(videoSize, transform);
    }

    public Size getVideoSize() {
        return videoSize;
    }

    /** Inverse of touch mapping: place physical camera geometry in the encoded video. */
    public Rect mapDeviceRect(Rect rect) {
        AffineMatrix inverse = videoToDeviceMatrix == null ? AffineMatrix.IDENTITY : videoToDeviceMatrix.invert();
        if (inverse == null) {
            return null;
        }
        Point[] corners = {new Point(rect.left, rect.top), new Point(rect.right, rect.top),
                new Point(rect.left, rect.bottom), new Point(rect.right, rect.bottom)};
        int left = Integer.MAX_VALUE, top = Integer.MAX_VALUE;
        int right = Integer.MIN_VALUE, bottom = Integer.MIN_VALUE;
        for (Point corner : corners) {
            Point point = inverse.apply(corner);
            left = Math.min(left, point.getX());
            top = Math.min(top, point.getY());
            right = Math.max(right, point.getX());
            bottom = Math.max(bottom, point.getY());
        }
        return new Rect(left, top, right, bottom);
    }

    public Point map(Position position) {
        Size clientVideoSize = position.getScreenSize();
        if (!videoSize.equals(clientVideoSize)) {
            // The client sends a click relative to a video with wrong dimensions,
            // the device may have been rotated since the event was generated, so ignore the event
            return null;
        }

        Point point = position.getPoint();
        if (videoToDeviceMatrix != null) {
            point = videoToDeviceMatrix.apply(point);
        }
        return point;
    }
}
