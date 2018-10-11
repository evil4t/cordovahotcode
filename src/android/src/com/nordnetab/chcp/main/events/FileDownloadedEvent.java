package com.nordnetab.chcp.main.events;

import com.nordnetab.chcp.main.config.FilesDownloadConfig;

/**
 * Created by evil4t on 2018/3/28.
 */

public class FileDownloadedEvent extends WorkerEvent {

    public static final String EVENT_NAME = "chcp_filedownloaded";

    /**
     * Class constructor
     *
     * @param config application config that was used for update download
     */
    public FileDownloadedEvent(FilesDownloadConfig config) {
        super(EVENT_NAME, config);
    }
}
