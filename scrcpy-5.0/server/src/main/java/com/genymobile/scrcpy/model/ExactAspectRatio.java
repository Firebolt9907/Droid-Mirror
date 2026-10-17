package com.genymobile.scrcpy.model;

import java.util.function.BiPredicate;

/** Select whole-pixel sizes without independently rounding the two dimensions. */
public final class ExactAspectRatio {
    private ExactAspectRatio() {}

    public static int[] fit(int width, int height, int maxSize, int alignment, BiPredicate<Integer, Integer> supported) {
        if (width <= 0 || height <= 0 || maxSize < 0 || alignment <= 0 || (alignment & (alignment - 1)) != 0)
            throw new IllegalArgumentException("Invalid exact-aspect capture constraints");
        int divisor = gcd(width, height);
        int unitWidth = width / divisor, unitHeight = height / divisor;
        int maximum = maxSize == 0 ? divisor : Math.min(divisor, maxSize / Math.max(unitWidth, unitHeight));
        // The reduced ratio is coprime, so both dimensions are multiples of the
        // encoder alignment exactly when their common multiplier is too.
        for (int multiplier = maximum / alignment * alignment; multiplier > 0; multiplier -= alignment) {
            int w = unitWidth * multiplier, h = unitHeight * multiplier;
            if (supported == null || supported.test(w, h)) return new int[]{w, h};
        }
        throw new IllegalArgumentException("No exact-aspect capture size fits the resolution limit and encoder alignment");
    }

    private static int gcd(int a, int b) {
        while (b != 0) { int remainder = a % b; a = b; b = remainder; }
        return a;
    }
}
