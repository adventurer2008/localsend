package org.localsend.sharefixture;

import android.app.Activity;
import android.content.ClipData;
import android.content.ComponentName;
import android.content.ContentProvider;
import android.content.ContentValues;
import android.content.Intent;
import android.database.Cursor;
import android.database.MatrixCursor;
import android.net.Uri;
import android.os.Bundle;
import android.os.ParcelFileDescriptor;
import android.provider.OpenableColumns;
import android.util.Base64;
import java.io.File;
import java.io.FileOutputStream;
import java.io.FileNotFoundException;
import java.io.IOException;
import java.util.ArrayList;

public class ShareFixture extends Activity {
  @Override public void onCreate(Bundle state) {
    super.onCreate(state);
    String mode = getIntent().getStringExtra("mode");
    boolean multi = "multi".equals(mode);
    Uri uri = Uri.parse("content://org.localsend.sharefixture.files/" + mode + ".png");
    Intent share = new Intent(multi ? Intent.ACTION_SEND_MULTIPLE : Intent.ACTION_SEND);
    share.setComponent(new ComponentName("org.localsend.localsend_app.remote", "org.localsend.localsend_app.MainActivity"));
    share.setType("image/png");
    share.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
    ClipData clip = ClipData.newUri(getContentResolver(), "test image", uri);
    if (multi) {
      Uri second = Uri.parse("content://org.localsend.sharefixture.files/second.png");
      clip.addItem(new ClipData.Item(second));
      ArrayList<Uri> streams = new ArrayList<>();
      streams.add(uri);
      streams.add(second);
      share.putParcelableArrayListExtra(Intent.EXTRA_STREAM, streams);
    } else if (!"warm".equals(mode)) {
      share.putExtra(Intent.EXTRA_STREAM, uri);
    }
    share.setClipData(clip);
    startActivity(share);
    finish();
  }

  public static class Files extends ContentProvider {
    @Override public boolean onCreate() { return true; }
    @Override public String getType(Uri uri) { return "image/png"; }
    @Override public Cursor query(Uri uri, String[] projection, String selection, String[] args, String order) {
      MatrixCursor cursor = new MatrixCursor(new String[] {OpenableColumns.DISPLAY_NAME});
      cursor.addRow(new Object[] {uri.getLastPathSegment()});
      return cursor;
    }
    @Override public ParcelFileDescriptor openFile(Uri uri, String mode) throws FileNotFoundException {
      try {
        File file = new File(getContext().getCacheDir(), uri.getLastPathSegment());
        byte[] image = Base64.decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jJ1EAAAAASUVORK5CYII=", Base64.DEFAULT);
        try (FileOutputStream output = new FileOutputStream(file)) { output.write(image); }
        return ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY);
      } catch (IOException failure) {
        throw new FileNotFoundException("Could not stage fixture");
      }
    }
    @Override public Uri insert(Uri u, ContentValues v) { return null; }
    @Override public int delete(Uri u, String s, String[] a) { return 0; }
    @Override public int update(Uri u, ContentValues v, String s, String[] a) { return 0; }
  }
}

