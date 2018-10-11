package com.nordnetab.chcp.main.events;

import com.nordnetab.chcp.main.config.ApplicationConfig;
import com.nordnetab.chcp.main.model.ChcpError;

/**
 * Created by Nikolay Demyankov on 25.08.15.
 * <p/>
 * Event is send when there is nothing new to download from server.
 */
public class CheckUpdateSuccessEvent extends WorkerEvent {

    public static final String EVENT_NAME = "chcp_checkUpdateSuccess";

    /**
     * Class constructor.
     *
     * @param config application config that was used for update download
     */
    public CheckUpdateSuccessEvent(ApplicationConfig config) {
        super(EVENT_NAME, null, config);
    }

}
