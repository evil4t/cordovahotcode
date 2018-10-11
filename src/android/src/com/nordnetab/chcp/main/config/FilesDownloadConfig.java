package com.nordnetab.chcp.main.config;

import org.json.JSONException;
import org.json.JSONObject;

/**
 * Created by evil4t on 2018/3/28.
 */

public class FilesDownloadConfig {

    private int totalfiles;
    private int currentfile;

    public FilesDownloadConfig(int totalfiles) {
        this.totalfiles = totalfiles;
        this.currentfile = 0;
    }

    public int getTotalfiles() {
        return totalfiles;
    }

    public void setTotalfiles(int totalfiles) {
        this.totalfiles = totalfiles;
    }

    public int getCurrentfile() {
        return currentfile;
    }

    public void setCurrentfile(int currentfile) {
        this.currentfile = currentfile;
    }

    @Override
    public String toString() {
        JSONObject object = new JSONObject();
        try {
            object.put("totalfiles", totalfiles);
            object.put("currentfile", currentfile);
        } catch (JSONException e) {
            e.printStackTrace();
        }
        return object.toString();
    }
}
