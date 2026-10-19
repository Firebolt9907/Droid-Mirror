package com.genymobile.scrcpy.control;

import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

public final class SecureWindowMonitorTests {
    private static void check(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }

    public static void main(String[] args) throws Exception {
        AtomicInteger queries = new AtomicInteger();
        AtomicInteger replies = new AtomicInteger();
        CountDownLatch queryStarted = new CountDownLatch(1);
        CountDownLatch finishQuery = new CountDownLatch(1);
        CountDownLatch currentReply = new CountDownLatch(1);
        SecureWindowMonitor monitor = new SecureWindowMonitor(() -> 0, (state, generation) -> {
            check(generation == 3, "Cancelled query must not publish a stale reply");
            check(state == SecureWindowState.SECURE, "Current query result");
            replies.incrementAndGet();
            currentReply.countDown();
        }, () -> {
            int count = queries.incrementAndGet();
            if (count == 1) {
                queryStarted.countDown();
                try { check(finishQuery.await(2, TimeUnit.SECONDS), "Release slow query"); }
                catch (InterruptedException interrupted) { throw new AssertionError(interrupted); }
            }
            return SecureWindowState.SECURE;
        });
        monitor.start();
        try {
            Thread.sleep(150);
            check(queries.get() == 0, "No dumpsys polling before a black-frame candidate");
            monitor.setCandidate(true, 1);
            check(queryStarted.await(1, TimeUnit.SECONDS), "Black frame must wake the monitor immediately");
            monitor.setCandidate(false, 2); // Normal video returns before the shell query completes.
            finishQuery.countDown();
            Thread.sleep(150);
            check(replies.get() == 0, "Late secure result must not escape after normal video");
            check(queries.get() == 1, "No query while normal video is playing");
            monitor.setCandidate(true, 3);
            check(currentReply.await(1, TimeUnit.SECONDS), "New black episode must receive its own result");
            Thread.sleep(650);
            check(queries.get() >= 3, "Static black screens continue refreshing without new video frames");
            monitor.setCandidate(false, 4);
            int stoppedAt = queries.get();
            Thread.sleep(650);
            check(queries.get() == stoppedAt, "Normal frames cancel periodic refresh");
        } finally {
            finishQuery.countDown();
            monitor.stop();
        }
        System.out.println("PASS: monitor sleeps during normal video, wakes on black, rejects slow/stale replies and cancels refresh");
    }
}
