package com.vistay.media.adapter.in.graphql;

import org.springframework.graphql.data.method.annotation.QueryMapping;
import org.springframework.stereotype.Controller;

@Controller
public class ServiceInfoQuery {

    @QueryMapping
    public ServiceInfo mediaServiceInfo() {
        return new ServiceInfo("media", "0.1.0");
    }

    public record ServiceInfo(String name, String version) {
    }
}

