import { fetchUrl, request } from "fakehttp";

request(process.argv[2]);
fetchUrl(process.argv[3]);
