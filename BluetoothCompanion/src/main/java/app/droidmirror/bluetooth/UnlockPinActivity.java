package app.droidmirror.bluetooth;

import com.genymobile.scrcpy.control.PinUnlock;

import android.app.Activity;
import android.app.KeyguardManager;
import android.content.Intent;
import android.os.Bundle;
import android.text.InputType;
import android.view.View;
import android.view.WindowManager;
import android.widget.*;
import java.util.Arrays;

/** Local-only credential editor. Never displays the stored PIN or saves field state. */
public final class UnlockPinActivity extends Activity {
    private EditText pin, confirmation;
    private TextView status;
    private boolean awaitingConfirmation;
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_SECURE);
        setTitle("Automatic unlock");
        KeyguardManager keyguard = getSystemService(KeyguardManager.class);
        Intent confirm = keyguard.createConfirmDeviceCredentialIntent("Automatic unlock", "Confirm your phone lock to manage the saved PIN.");
        if (confirm == null) { finish(); return; }
        // Always authenticate anew after recreation; no saved authorization flag.
        awaitingConfirmation = state != null && state.getBoolean("awaitingConfirmation");
        if (!awaitingConfirmation) { awaitingConfirmation = true; startActivityForResult(confirm, 1); }
    }
    @Override protected void onActivityResult(int request, int result, Intent data) {
        super.onActivityResult(request, result, data);
        if (request != 1) return;
        if (result != RESULT_OK) { finish(); return; }
        awaitingConfirmation = false;
        editor();
    }
    @Override protected void onSaveInstanceState(Bundle state) {
        state.putBoolean("awaitingConfirmation", awaitingConfirmation);
        super.onSaveInstanceState(state);
    }
    private void editor() {
        LinearLayout layout = new LinearLayout(this); layout.setOrientation(LinearLayout.VERTICAL);
        int padding = (int) (24 * getResources().getDisplayMetrics().density);
        layout.setPadding(padding, padding, padding, padding);
        TextView detail = new TextView(this);
        detail.setText("Optionally save your phone’s numeric screen-lock PIN (4–16 digits). DroidMirror enters it once before video starts, returning to your last app or home screen. Keep your phone locked before connecting.\n\nThe PIN is encrypted on this phone using Android Keystore and never sent to your Mac. Enabling this lets your paired Mac unlock your phone without a local confirmation. Use only a Mac you trust.\n\nAutomatic PIN entry has a 15-second cooldown between unsuccessful attempts. Mirroring still works for manual unlock during the cooldown. Afterward, a new connection can try the saved PIN again; there are no automatic background retries. Remove or update it when your screen-lock PIN changes.\n");
        layout.addView(detail);
        status = new TextView(this); layout.addView(status); updateStatus();
        pin = field("Phone PIN", layout); confirmation = field("Confirm PIN", layout);
        Button save = new Button(this); save.setText("Save PIN and enable automatic unlock"); layout.addView(save);
        save.setOnClickListener(v -> {
            byte[] value = new byte[pin.length()];
            try {
                if (!android.text.TextUtils.equals(pin.getText(), confirmation.getText())) {
                    status.setText("PINs do not match."); return;
                }
                for (int i = 0; i < value.length; i++) {
                    char digit = pin.getText().charAt(i);
                    if (digit < '0' || digit > '9') throw new IllegalArgumentException();
                    value[i] = (byte) digit;
                }
                if (!PinUnlock.valid(value)) { status.setText("Use a PIN of 4–16 digits."); return; }
                SavedUnlockPin.save(this, value); updateStatus();
            } catch (Exception error) { status.setText("Could not save PIN. Use 4–16 digits and try again."); }
            finally { Arrays.fill(value, (byte) 0); clearFields(); }
        });
        Button remove = new Button(this); remove.setText("Remove saved PIN"); layout.addView(remove);
        remove.setOnClickListener(v -> {
            try { SavedUnlockPin.remove(this); clearFields(); updateStatus(); }
            catch (Exception error) { status.setText("Could not remove PIN. Try again."); }
        });
        ScrollView scroll = new ScrollView(this); scroll.addView(layout); setContentView(scroll);
    }
    private EditText field(String hint, LinearLayout layout) {
        EditText field = new EditText(this); field.setHint(hint);
        field.setInputType(InputType.TYPE_CLASS_NUMBER | InputType.TYPE_NUMBER_VARIATION_PASSWORD);
        field.setFilters(new android.text.InputFilter[]{new android.text.InputFilter.LengthFilter(16)});
        field.setSaveEnabled(false); field.setImportantForAutofill(View.IMPORTANT_FOR_AUTOFILL_NO_EXCLUDE_DESCENDANTS);
        field.setImeOptions(android.view.inputmethod.EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING);
        layout.addView(field); return field;
    }
    private void updateStatus() {
        status.setText(!SavedUnlockPin.configured(this) ? "No PIN saved. Automatic unlock is off."
            : SavedUnlockPin.paused(this) ? "PIN entry is cooling down for up to 15 seconds; streaming still works with manual unlock."
            : "PIN saved. Automatic unlock is enabled.");
    }
    private void clearFields() { if (pin != null) pin.getText().clear(); if (confirmation != null) confirmation.getText().clear(); }
    @Override protected void onStop() { clearFields(); super.onStop(); }
}
